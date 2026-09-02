# Hermetiq Buildbarn Helm Chart

This chart deploys the Buildbarn services used by Hermetiq for remote cache,
remote execution, Buildbarn Browser, and optionally the Remote Asset API. It is
the detailed reference for the chart internals.

![Hermetiq Buildbarn deployment architecture](https://raw.githubusercontent.com/Hermetiq/hermetiq-k8s/main/hermetiq-buildbarn-diagram.png)

Use the repository's
[installation guide](https://github.com/Hermetiq/hermetiq-k8s#readme) for the
supported full-stack deployment order and external dependencies.

For Buildbarn upstream background, see https://github.com/buildbarn.

## Contents

- [What The Chart Deploys](#what-the-chart-deploys)
- [Install](#install)
- [Service Topology](#service-topology)
- [Jsonnet Config Model](#jsonnet-config-model)
- [Per-File Jsonnet Overrides](#per-file-jsonnet-overrides)
- [Routing And TLS](#routing-and-tls)
  - [Envoy Gateway policies](#envoy-gateway-policies)
  - [Tuning the downstream leg for high-RTT Bazel clients](#tuning-the-downstream-leg-for-high-rtt-bazel-clients)
  - [TLS certificates](#tls-certificates)
- [Storage](#storage)
  - [Raw block-device storage](#raw-block-device-storage)
  - [Initial Size Class Cache (ISCC) and File System Access Cache (FSAC)](#initial-size-class-cache-iscc-and-file-system-access-cache-fsac)
  - [DIY mirrored storage (advanced)](#diy-mirrored-storage-advanced)
- [Browser SSO](#browser-sso)
  - [Custom auth sidecar hook](#custom-auth-sidecar-hook)
- [Frontend Authentication And Writes](#frontend-authentication-and-writes)
- [JWKS ConfigMap Management](#jwks-configmap-management)
- [Tracing, Metrics, And Diagnostics](#tracing-metrics-and-diagnostics)
- [Remote Asset API](#remote-asset-api)
- [bb-portal](#bb-portal)
- [Worker And Runner](#worker-and-runner)
- [Worker Autoscaling](#worker-autoscaling)
- [Testcontainers Worker Fleets](#testcontainers-worker-fleets)
  - [DinD Fleet](#dind-fleet)
  - [Sysbox Fleet](#sysbox-fleet)
  - [Routing](#routing)
  - [Node Pool Prerequisites](#node-pool-prerequisites)
  - [Operational notes](#operational-notes)
- [Security And Availability Hardening](#security-and-availability-hardening)
  - [Restricting direct storage access](#restricting-direct-storage-access)
- [Scheduling](#scheduling)
- [Verification](#verification)
- [Hermetiq grpc-cache-proxy sidecar](#hermetiq-grpc-cache-proxy-sidecar)
  - [How lookups are classified](#how-lookups-are-classified)
  - [Project attribution](#project-attribution)
  - [Hermetiq side](#hermetiq-side)
  - [Verify the sidecar](#verify-the-sidecar)
- [License](#license)

## What The Chart Deploys

Core resources:

- `buildbarn-config` ConfigMap for browser, frontend, scheduler, storage, and remote asset Jsonnet.
- `buildbarn-worker-config` ConfigMap for worker and runner Jsonnet, available to operator-managed or legacy chart-managed workers.
- `browser` Deployment and Service.
- `frontend` Deployment plus `frontend-grpc` Service.
- `scheduler-ubuntu22-04` Deployment and `scheduler` Service.
- `storage` StatefulSet and headless `storage` Service.
- Optional `bb-portal` Deployment and Service when `portal.enabled=true` (see [bb-portal](#bb-portal)).
- Optional `frontend-internal` ClusterIP Service for trusted in-cluster clients when `frontend.internalService.enabled=true`.
- Optional `NetworkPolicy` restricting the storage gRPC port to Buildbarn components and named peers when `storage.networkPolicy.enabled=true`.
- Optional legacy `worker-ubuntu22-04` Deployment and matching KEDA `ScaledObject` when `workerUbuntu2204.enabled=true`.
- Optional `worker-testcontainers` Deployment (with a Docker-in-Docker sidecar) and matching KEDA `ScaledObject` for Bazel actions that need a Docker daemon.
- Optional `worker-testcontainers-sysbox` Deployment and matching KEDA `ScaledObject` for Bazel actions that need Docker inside a Sysbox runtime.
- Optional `remote-asset` Deployment plus `remote-asset` and `remote-asset-grpc` Services.
- Optional PodDisruptionBudgets for storage, frontend, scheduler, Browser, and remote asset workloads.
- Optional cert-manager `Certificate` for Contour or Ingress routing.
- Contour `HTTPProxy`, Gateway API `HTTPRoute`/`GRPCRoute`, or nginx-style `Ingress` resources.
- Optional VictoriaMetrics `VMPodScrape` and `VMRule` resources.
- Optional JWKS sync ServiceAccount, RBAC, CronJob, and initial sync Job.

Worker pools are expected to be managed by the Buildbarn Worker operator by
default. Set `workerUbuntu2204.enabled=true` only when you intentionally want
this chart to keep rendering the legacy Ubuntu 22.04 worker Deployment.
`worker-testcontainers` and `worker-testcontainers-sysbox` remain opt-in
chart-managed fleets for tests/actions that need Docker (see
[Testcontainers worker fleets](#testcontainers-worker-fleets)).

## Install

```bash
helm upgrade --install --namespace hermetiq buildbarn \
  oci://ghcr.io/hermetiq/buildbarn \
  --version 0.9.0 \
  --values buildbarn-values.yaml
```

By default, namespaced resources render into `hermetiq`:

```yaml
namespaceOverride: hermetiq
createNamespace: false
```

Set `createNamespace: true` if Helm should create that namespace, or override
`namespaceOverride` to render into a different namespace.

Inspect the packaged documentation and defaults before creating overrides:

```bash
helm show readme oci://ghcr.io/hermetiq/buildbarn --version 0.9.0
helm show values oci://ghcr.io/hermetiq/buildbarn --version 0.9.0
```

Contributors can render the checked-out chart locally:

```bash
helm template buildbarn ./charts/buildbarn \
  --namespace hermetiq \
  --values custom-values/buildbarn-values.yaml > /tmp/buildbarn.yaml
```

## Service Topology

The chart follows Buildbarn's standard split:

- Clients connect to `frontend-grpc` for Remote Execution, CAS, ByteStream, and Action Cache APIs.
- `frontend` forwards execution requests to `scheduler`.
- `scheduler` assigns queued operations to workers matching the requested platform properties.
- `worker` containers fetch inputs from CAS, mount or materialize build inputs, call their local `runner` over a Unix socket, and upload outputs back to CAS.
- `storage` shards hold CAS and Action Cache data on persistent disks.
- `browser` provides the Buildbarn Browser UI.
- `remote-asset`, when enabled, serves the Bazel Remote Asset Fetch API and stores fetched blobs in CAS.
- `bb-portal`, when enabled, serves the bb-portal build-event dashboard and BES endpoint (see [bb-portal](#bb-portal)).

The default host names derive from `hosts.domainBase`:

```yaml
hosts:
  domainBase: bb.helm.hermetiq.dev
```

This produces:

- `browser.<domainBase>` for Buildbarn Browser.
- `bb.<domainBase>` for frontend gRPC.
- `rbe-web.<domainBase>` for scheduler web UI.
- `asset.<domainBase>` for Remote Asset API when enabled.
- `portal.<domainBase>` and `bes.<domainBase>` for bb-portal when enabled.

Set `hosts.browser`, `hosts.frontendGrpc`, `hosts.rbeWeb`, `hosts.remoteAsset`,
`hosts.portal`, or `hosts.bes` to override any individual host.

## Jsonnet Config Model

Buildbarn itself is configured through Jsonnet. The chart renders two ConfigMaps:

- `buildbarn-config` from the chart's `files/config/` directory.
- `buildbarn-worker-config` from the chart's `files/worker-config/` directory.

`buildbarn-worker-config` also includes the top-level `common.libsonnet`, so
worker and runner configs use the same sharded storage, message size, tracing,
and diagnostics defaults as the rest of the chart.

Some Jsonnet files are Helm-templated before landing in the ConfigMap. For
example:

- `common.libsonnet` renders storage shard addresses and tracing settings.
- `frontend.jsonnet` renders JWKS auth, CAS/Action Cache/Execute authorizers, read cache settings, and trace attributes.
- `storage.jsonnet` renders persistence sizing.
- `worker-common.libsonnet` renders worker concurrency, caches, platform properties, completed action logging, and runner options.
- `asset.jsonnet` renders Remote Asset API port and fetch/push behavior.

## Per-File Jsonnet Overrides

Use `configOverrides` or `workerConfigOverrides` when a value is too specific or
too deep for the chart values model:

```bash
helm upgrade --install --namespace hermetiq buildbarn \
  oci://ghcr.io/hermetiq/buildbarn \
  --version 0.9.0 \
  --values buildbarn-values.yaml \
  --set-file 'configOverrides.frontend\.jsonnet'=./my-frontend.jsonnet \
  --set-file 'workerConfigOverrides.worker-ubuntu22-04\.jsonnet'=./my-worker.jsonnet
```

Keys must match a filename in `files/config/` or `files/worker-config/`.
Unknown keys fail `helm template` with the valid filenames.

Overrides are verbatim. Helm templating is not applied to override contents, so
if you override a templated file you own all values that the chart would normally
inject into that file.

Override-able files:

| Map | Filename |
| --- | --- |
| `configOverrides` | `asset.jsonnet` |
| `configOverrides` | `browser.jsonnet` |
| `configOverrides` | `common.libsonnet` |
| `configOverrides` | `frontend.jsonnet` |
| `configOverrides` | `scheduler.jsonnet` |
| `configOverrides` | `portal.jsonnet` |
| `configOverrides` | `storage.jsonnet` |
| `workerConfigOverrides` | `runner-testcontainers-sysbox.jsonnet` |
| `workerConfigOverrides` | `runner-testcontainers.jsonnet` |
| `workerConfigOverrides` | `runner-ubuntu22-04.jsonnet` |
| `workerConfigOverrides` | `worker-common.libsonnet` |
| `workerConfigOverrides` | `worker-testcontainers-sysbox.jsonnet` |
| `workerConfigOverrides` | `worker-testcontainers.jsonnet` |
| `workerConfigOverrides` | `worker-ubuntu22-04.jsonnet` |

`configOverrides.common.libsonnet` propagates to both ConfigMaps.

## Routing And TLS

The chart supports four built-in routing providers plus a disabled mode for
user-managed routing:

```yaml
routing:
  enabled: true
  provider: contour # contour, gateway, gateway-httproute-only, ingress, or none
```

`contour` renders:

- `HTTPProxy` for frontend gRPC.
- `HTTPProxy` for Browser.
- `HTTPProxy` for RBE web scheduler.
- `HTTPProxy` for Remote Asset API when `remoteAsset.enabled` and `ingress.remoteAssetGrpc.enabled` are both true.
- `HTTPProxy` resources for bb-portal (`portal.` HTTP and `bes.` h2c gRPC) when `portal.enabled` is true.

`gateway` renders:

- `HTTPRoute` for Browser.
- `HTTPRoute` for RBE web scheduler.
- `GRPCRoute` for frontend gRPC.
- `GRPCRoute` for Remote Asset API when `remoteAsset.enabled` and `gateway.grpcRoutes.remoteAsset.enabled` are both true.
- `HTTPRoute` for the portal UI and `GRPCRoute` for BES when `portal.enabled` is true.
- Envoy Gateway `BackendTrafficPolicy` for long-lived frontend gRPC streams when enabled.
- Envoy Gateway `SecurityPolicy` for Browser CORS when enabled.
- Envoy Gateway `ClientTrafficPolicy` tuning downstream buffers, HTTP/2 flow control, and connection lifetime when enabled.

`gateway-httproute-only` renders:

- `HTTPRoute` for Browser.
- `HTTPRoute` for RBE web scheduler.
- `HTTPRoute` for frontend gRPC.
- `HTTPRoute` for Remote Asset API when `remoteAsset.enabled` and `gateway.grpcRoutes.remoteAsset.enabled` are both true.
- GKE `HealthCheckPolicy` and `GCPBackendPolicy` resources for the routed Services.

`ingress` renders nginx-style `Ingress` resources for Browser, RBE web,
frontend gRPC, Remote Asset API when `remoteAsset.enabled` and
`ingress.remoteAssetGrpc.enabled` are both true, and bb-portal (`portal.` plus
a GRPC-protocol `bes.` Ingress) when `portal.enabled` is true.

Set `routing.enabled=false` or `routing.provider=none` when you want the chart
to render only internal Services and application resources while you supply
your own Gateway, Ingress, HTTPProxy, service mesh route, or other external
routing implementation. Route TLS Certificates, Envoy Gateway policies, and GKE
Gateway policies are also skipped in this mode.

Gateway modes assume TLS is configured on the referenced Gateway. **Note:**
switching to `gateway` or `gateway-httproute-only` from `contour` or `ingress`
stops rendering the cert-manager `Certificate` resource even when
`certificate.enabled` is true. You must configure TLS termination on your
Gateway listener.

Set `gateway.name` and optionally `gateway.namespace`:

```yaml
routing:
  provider: gateway
gateway:
  name: shared-gateway
  namespace: gateway-system
```

For advanced Gateway API parent references, set `gateway.parentRefs` directly.
When non-empty, it overrides `gateway.name` and `gateway.namespace`.

Use `gateway-httproute-only` for GKE Gateway, which supports HTTPRoute but not
GRPCRoute. Use `gateway` for Envoy Gateway and other controllers that support
GRPCRoute. If your cluster uses older Gateway API CRDs, override
`gateway.httpRouteApiVersion` or `gateway.grpcRouteApiVersion`.

### Envoy Gateway policies

`routing.provider=gateway` renders Envoy Gateway `gateway.envoyproxy.io`
resources alongside the standard routes: `BackendTrafficPolicy` for the
long-lived gRPC stream timeouts, `SecurityPolicy` for Browser CORS, and the
optional `ClientTrafficPolicy`. On a `GRPCRoute`-capable controller that is not
Envoy Gateway those kinds do not exist and the install fails on unknown kinds.
Disable them:

```yaml
gateway:
  cors:
    enabled: false
  grpcRoutes:
    frontend:
      backendTrafficPolicy:
        enabled: false
    bes:
      backendTrafficPolicy:
        enabled: false
    remoteAsset:
      backendTrafficPolicy:
        enabled: false
  clientTrafficPolicy:
    enabled: false
```

Without the timeout policies, whatever default route timeout your controller
applies governs `ByteStream` transfers and BES uploads; check that it does not
truncate them.

### Tuning the downstream leg for high-RTT Bazel clients

`gateway.clientTrafficPolicy` renders an Envoy Gateway `ClientTrafficPolicy`
(`routing.provider=gateway` only) covering the client → Envoy leg. It is
disabled by default; enable it when Bazel clients are far from the cluster.

> **Installing the hermetiq chart too?** Enable it there instead. The policy is
> Gateway-scoped, so one covers both charts' routes, and `ClientTrafficPolicy`
> resources do not merge — enable it in exactly one chart or the oldest wins and
> the other reports `Overridden=True`. This copy is for standalone Buildbarn
> installs.

```yaml
routing:
  provider: gateway
gateway:
  name: shared-gateway
  clientTrafficPolicy:
    enabled: true
    # Optional: restrict to one listener instead of the whole Gateway.
    sectionName: https
```

Envoy Gateway's own defaults are conservative for remote cache/execution
traffic. Measured against v1.7.2, it programs a 32Ki per-connection buffer
limit, a 64Ki HTTP/2 stream window, a 1Mi connection window, 100 concurrent
streams, and a 1h idle timeout. The per-connection buffer limit matters most:
at 32Ki, CAS blob transfer hits watermark backpressure almost immediately and
every drain/refill cycle costs a full client round trip. The HTTP/2 windows are
a second, independent cap — raising only `bufferLimit` can still produce
`413 request_payload_too_large`.

Two caveats. `bufferLimit` is per-connection memory on the Envoy proxy, which
frequently runs a single replica, so watch its RSS after enabling. And a policy
without `sectionName` applies to every route on the Gateway, not just
Buildbarn's — `ClientTrafficPolicy` resources do not merge, so a listener-scoped
policy fully overrides a Gateway-scoped one rather than combining with it.

Some adjacent knobs are deliberately not exposed. `spec.timeout.tcp` only
applies to TCP and TLS-passthrough listeners, so it is a silent no-op where
Envoy terminates TLS and speaks HTTP/2. `spec.connection.connectionLimit` risks
capping concurrency for little benefit at build-cluster client counts. HTTP/2
keepalive PINGs are not part of `ClientTrafficPolicy` at all and need an
`EnvoyPatchPolicy`. Raising the idle timeout is what actually prevents
connection churn: Envoy's HTTP idle timeout is request-based, so neither PINGs
nor TCP keepalives reset it.

### TLS certificates

Contour and Ingress modes use a shared TLS secret. If `tls.secretName` is set,
the chart uses that existing Secret. Otherwise, when `certificate.enabled` is
true, it renders a cert-manager `Certificate` named by `certificate.name` with
`*.hosts.domainBase` plus the concrete Browser, frontend gRPC, RBE web, and
optional Remote Asset hostnames.

`certificate.enabled` defaults to `true` and `certificate.issuerRef.name`
defaults to `lets-encrypt-issuer`, so a Contour or Ingress install renders a
`bb-wildcard-cert` Certificate unless you act. Point `certificate.issuerRef` at
a `ClusterIssuer` that exists in your cluster, set `tls.secretName` to reuse a
wildcard Secret you already manage, or set `certificate.enabled: false`. If the
referenced issuer does not exist, the Certificate stays pending and the routes
serve no usable TLS.

## Storage

Storage is a sharded StatefulSet. The number of shards is `storage.replicas`;
`common.libsonnet` generates one CAS and Action Cache shard entry per replica.

Use the focused repository runbooks for planning and live operations:

- [storage model and sizing](https://github.com/Hermetiq/hermetiq-k8s/blob/main/docs/buildbarn-storage-model.md)
- [storage operations](https://github.com/Hermetiq/hermetiq-k8s/blob/main/docs/buildbarn-storage-operations.md)
- [raw block-device storage](https://github.com/Hermetiq/hermetiq-k8s/blob/main/docs/buildbarn-block-storage.md)
- [ISCC size classes](https://github.com/Hermetiq/hermetiq-k8s/blob/main/docs/iscc-size-classes.md)

The chart stores CAS and Action Cache data on PVC-backed persistent disks by
default:

```yaml
storage:
  replicas: 5
  persistence:
    mode: pvc
    cas:
      storageClassName: premium-rwo
      size: 1Ti
      blocksSizeGi: 900
    ac:
      storageClassName: premium-rwo
      size: 20Gi
      blocksSizeGi: 10
```

`blocksSizeGi` must leave headroom for metadata, persistent state, and database
files. Changing shard count or storage layout after builds have run can invalidate
or strand cache data, so size these values carefully before production use.

For maximum local I/O, you can opt into ephemeral NVMe-backed storage without
PVCs. This is cache storage: Pod recreation, node drain, node repair, node loss,
or rescheduling can erase a shard. There is no automatic data migration between
PVC, `emptyDir`, and `hostPath`; changing an existing release requires manually
recreating the StatefulSet because `volumeClaimTemplates` are effectively
immutable.

On GKE Local SSD-backed ephemeral storage node pools, prefer `emptyDir` and
schedule the storage pods onto nodes with the Local SSD ephemeral-storage label:

```yaml
storage:
  nodeSelector:
    cloud.google.com/gke-ephemeral-storage-local-ssd: "true"
  resources:
    requests:
      ephemeral-storage: 900Gi
    limits:
      ephemeral-storage: 1000Gi
  persistence:
    mode: emptyDir
    cas:
      size: 1000Gi
      blocksSizeGi: 900
      emptyDir:
        sizeLimit: 1000Gi
    ac:
      size: 20Gi
      blocksSizeGi: 10
      emptyDir:
        sizeLimit: 20Gi
```

If your nodes expose mounted NVMe storage through a stable path, use `hostPath`:

```yaml
storage:
  nodeSelector:
    cloud.google.com/gke-ephemeral-storage-local-ssd: "true"
  persistence:
    mode: hostPath
    cas:
      hostPath:
        path: /mnt/stateful_partition/kube-ephemeral-ssd/buildbarn-storage/cas
        type: DirectoryOrCreate
    ac:
      hostPath:
        path: /mnt/stateful_partition/kube-ephemeral-ssd/buildbarn-storage/ac
        type: DirectoryOrCreate
```

Storage pods are resource intensive in production. Make sure the target namespace
has quota for the configured CPU, memory, disk, or ephemeral-storage requests.

### Raw block-device storage

Each store can instead put its blocks on a **raw block device** (`volumeMode: Block`)
rather than a file on a filesystem, avoiding the filesystem layer. Set a store's
`backend: blockDevice`. The blocks then live on a dedicated `volumeMode: Block` PVC
(claim `<store>-blocks`, surfaced in the pod at `/dev/bb/<store>`) whose full capacity
becomes the block store — Buildbarn auto-infers the block size, so `blocksSizeGi` is
ignored in this mode.

The key-location map (KLM) defaults to **in memory** (`keyLocationMap: inMemory`),
which is simplest but **not persistent** — the store is empty after a storage-pod
restart. RAM use scales with `keyLocationMapInMemoryEntries` (~64 bytes/entry), so
size it against the pod memory limit. To persist across restarts, set
`keyLocationMap: file`: the KLM file and the `persistent_state` directory then live on
a small companion `volumeMode: Filesystem` PVC (claim `<store>-meta`).

```yaml
storage:
  persistence:
    mode: pvc
    cas:
      backend: blockDevice
      blockDevice:
        storageClassName: bb-block-hyperdisk   # must support volumeMode: Block
        size: 1000Gi
        keyLocationMap: inMemory               # or "file" for persistence
        keyLocationMapInMemoryEntries: 20000000
```

**Device access / Pod Security (differs by mode — validate on your cluster).** The
storage pod runs as uid/gid 65534. Filesystem PVC/`emptyDir` volumes are prepared by a
non-root init container using the pod `fsGroup`. Raw block devices additionally require
the container to *open* the device node, and Kubernetes only adds a device to a
container's device cgroup when it is attached through a **PVC** (`volumeDevices`). This
splits the two provisioning modes:

- **PVC-backed block (Example A, `mode: pvc`)** — attached via `volumeDevices`, so the
  kubelet wires the device cgroup and the storage container stays **non-privileged**.
  `storage.persistence.blockDevice.deviceAccess` then only fixes the node's file
  ownership:
  - `group` (default) — pod `fsGroup`/`supplementalGroups` (group `disk`); PSS
    **restricted**-compatible, but only if the CSI presents the device group-accessible
    (GKE PD CSI presents `root:root`, where this grants nothing — verify on your driver).
  - `chownInit` — a root, `CHOWN`-only init container chowns the device node; needs a
    **baseline** namespace / PSA exemption. Set `blockDevice.deviceInit.privileged: true`
    only if `CHOWN` alone is refused.
- **hostPath block (Example B, `mode: hostPath` + `allowHostPath: true`)** —
  `volumeDevices` cannot reference a hostPath source, so the device node is bind-mounted
  as a `volumeMounts` entry, which Kubernetes does **not** cgroup-allowlist. The chart
  therefore runs the storage container **`privileged: true`** in this mode (there is no
  non-privileged hostPath-block option), and `deviceAccess: chownInit` chowns the
  root-owned node so uid 65534 can open it. Requires a baseline/privileged namespace.

**Upgrade / switching note.** `volumeClaimTemplates` are effectively immutable and
StatefulSet PVCs are retained. Block mode uses distinct claim names
(`<store>-blocks` / `<store>-meta`), so switching an existing release from
`filesystem` leaves the old `cas`/`ac` PVCs **orphaned** (still billing) — delete them
manually once the switch is confirmed. There is **no data migration**; the raw device
initializes empty. Changing block counts or the device size on a persistent store also
discards its data on the next start; plan such changes as cache flushes.
Enabling `storage.persistence.iscc.enabled` or `storage.persistence.fsac.enabled` on an
existing PVC-backed release also changes the StatefulSet's `volumeClaimTemplates`.
Plan a reviewed StatefulSet recreate/migration for that change; Helm cannot patch the
existing StatefulSet in place.

#### GKE example A — Persistent Disk / Hyperdisk (persistent, network-attached)

The GKE PD CSI driver supports `volumeMode: Block` natively — no DaemonSet needed.

```yaml
# StorageClass (apply separately or via .Values ... extraObjects)
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata: { name: bb-block-hyperdisk }
provisioner: pd.csi.storage.gke.io
parameters: { type: hyperdisk-balanced }   # or pd-ssd
volumeBindingMode: WaitForFirstConsumer     # binds in the pod's zone
reclaimPolicy: Retain                        # protect data on PVC delete
allowVolumeExpansion: true
```

`hyperdisk-balanced`/`pd-ssd` are **zonal**: `WaitForFirstConsumer` pins each replica to
its disk's zone, so a shard survives pod restart/reschedule within the zone, but not a
full-zone loss. Use a regional disk for cross-zone HA.

#### GKE example B — Local NVMe SSD via `partition_ephemeral_disks` (fastest, ephemeral)

Buildbarn's `partition_ephemeral_disks` tool (a DaemonSet) stripes a node's local NVMe
SSDs into an LVM2 volume group `ephemeral` and carves logical volumes, so pods can
consume raw block devices with fine-grained sizes. Suggested split: CAS 97%, AC 1%,
ISCC 1%, FSAC 1%. The storage pods then consume the LVs via `hostPath` block devices:

```yaml
storage:
  # Dedicated non-spot raw-block Local SSD pool (gcloud --local-nvme-ssd-block).
  # Do NOT target the cloud.google.com/gke-ephemeral-storage-local-ssd label:
  # that mode formats + mounts the SSDs as a filesystem, leaving no raw device
  # to partition.
  nodeSelector:
    node-type: ssd-block
  persistence:
    mode: hostPath
    blockDevice:
      allowHostPath: true         # required for backend=blockDevice with mode=hostPath
      deviceAccess: chownInit     # chown the root-owned device node for uid 65534
    cas:
      backend: blockDevice
      blockDevice:
        keyLocationMap: inMemory  # ephemeral storage => cache-only; no persistence
        hostPath:
          devicePath: /dev/ephemeral/cas
```

This path is cache-only: a node loss drops that shard. If you set `keyLocationMap: file`
here, co-locate the metadata on the **same** Local SSD
(`blockDevice.metadata.hostPath.path`) so state and blocks are wiped together — never on
a network PVC. In hostPath block mode the chart runs the **storage container
`privileged: true`** (device cgroup) alongside the `chownInit` device chown; that, plus
the privileged DaemonSet and `hostPath` block devices, requires a baseline/privileged
namespace or PSA exemption.

#### GKE example C — TopoLVM CSI (dynamic LVM block, non-privileged)

[TopoLVM](https://github.com/topolvm/topolvm) is a CSI driver that carves an LVM volume
group into logical volumes on demand and can provision them as `volumeMode: Block` PVCs.
It combines the strengths of Examples A and B: LVM-striped **local SSD** performance
*and* PVC-based attachment. Because the devices come from a PVC, the storage container
uses `volumeDevices` and stays **non-privileged** (the kubelet wires the device cgroup),
and there's **no `partition_ephemeral_disks` DaemonSet and no readiness gate** — TopoLVM
provisions each replica's LVs when the pod first schedules (`WaitForFirstConsumer`).

Prerequisites (one-time, on the raw-block Local SSD pool):
- An LVM volume group on the local SSDs. TopoLVM's `lvmd` manages LVs *within* a VG but
  does not build the VG from raw disks, so create it once per node — e.g. a
  `vgcreate`-only variant of the partition DaemonSet, or a node startup script.
- TopoLVM installed (its upstream Helm chart; depends on cert-manager) with an `lvmd`
  device-class pointing at that VG, plus a Block-capable StorageClass:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata: { name: topolvm-ssd }
provisioner: topolvm.io
parameters: { "topolvm.io/device-class": "ephemeral" }
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
```

Then consume it with the ordinary PVC block path — `mode: pvc`, no `hostPath`, no
privileged pod. Unlike the hostPath path, `blockDevice.size` is meaningful here (it's the
PVC request, i.e. the LV size TopoLVM carves per replica):

```yaml
storage:
  nodeSelector:
    node-type: ssd-block               # your raw-block Local SSD pool
  persistence:
    mode: pvc
    cas:
      backend: blockDevice
      blockDevice:
        storageClassName: topolvm-ssd
        size: 700Gi
        keyLocationMap: inMemory
    ac:   { backend: blockDevice, blockDevice: { storageClassName: topolvm-ssd, size: 8Gi } }
    iscc: { enabled: true, backend: blockDevice, blockDevice: { storageClassName: topolvm-ssd, size: 8Gi } }
    fsac: { enabled: true, backend: blockDevice, blockDevice: { storageClassName: topolvm-ssd, size: 8Gi } }
```

Device-node *file* ownership is still handled by `deviceAccess` exactly as in Example A —
try `group` (default; PSS restricted-compatible, works if TopoLVM presents the device
group-accessible) and fall back to `chownInit` (baseline namespace) if the node is
`root:root`. Either way the long-lived storage container is non-privileged, which is the
main advantage over the hostPath path.

### Initial Size Class Cache (ISCC) and File System Access Cache (FSAC)

Beyond CAS and Action Cache, bb-storage can host two optional stores, each served on the
same gRPC port and configured exactly like the other stores (`backend`, `blockDevice`,
sizes). Both are disabled by default.

- **ISCC** (`storage.persistence.iscc.enabled`) records prior action execution outcomes
  so bb-scheduler can pick the initial size class for future runs. Enable the scheduler
  consumer with `scheduler.sizeClassAnalysis.enabled: true`. **Only useful when your
  worker platforms declare multiple size classes.**
- **FSAC** (`storage.persistence.fsac.enabled`) records which input-root paths actions
  read, so workers can prefetch/read-ahead CAS objects. Enable per worker with
  `<worker>.config.prefetching.enabled: true`. **Requires the virtual (FUSE/NFS) build
  directory** (already enabled on the chart's workers).

The chart validates these dependencies (e.g. `sizeClassAnalysis` requires
`iscc.enabled`; a worker's `prefetching` requires `fsac.enabled` and its
`virtualBuildDirectory`).

### DIY mirrored storage (advanced)

bb-storage can mirror every store across two backends
(`MirroredBlobAccessConfiguration`): blobs are written to both, reads
round-robin between them, and `FindMissingBlobs` heals whichever side is
missing a blob. This chart intentionally does not model that topology, but
nothing in it prevents wiring one up through the existing escape hatches.
Before committing to it, understand what mirroring is:

- **Durability, not high availability.** With one side down, all writes and
  all `FindMissingBlobs` calls fail and about half of reads fail — builds
  stop. The payoff is that a destroyed side can be replaced by an *empty*
  one and refills automatically from the survivor: losing a ring no longer
  loses the cache, and one ring can be resharded or rebuilt at a time.
- **Twice the cost.** Two full shard rings: 2x pods, 2x disk, 2x write
  bandwidth.

The recipe, using chart values only:

1. **Topology** — replace `common.libsonnet` wholesale via
   `configOverrides["common.libsonnet"]`, wrapping each store's `sharding`
   block in `mirrored`. Put the mirror on top of two independent shard rings
   so each ring can be resized on its own. Ring A keeps today's addresses;
   ring B points at the StatefulSet you add in step 2:

   ```jsonnet
   contentAddressableStorage: {
     mirrored: {
       backendA: { sharding: { shards: { /* storage-{i}.storage.<ns>:8981 */ } } },
       backendB: { sharding: { shards: { /* storage-b-{i}.storage-b.<ns>:8981 */ } } },
       replicatorAToB: { 'local': {} },
       replicatorBToA: { 'local': {} },
     },
   },
   ```

   Apply the same wrapper to the Action Cache *inside* `completenessChecking`
   (keeping `actionResultExpiring` outermost when enabled) and to
   `initialSizeClassCache`/`fileSystemAccessCache` when enabled. The Action
   Cache, ISCC, and FSAC accept only `local`-family replicators
   (`local`/`queued`/`concurrencyLimiting`/`noop`); `remote` and
   `deduplicating` are CAS-only, and bb-storage rejects anything else at
   startup. The override must keep exporting every key consumers splat:
   `blobstore`, `initialSizeClassCache`/`fileSystemAccessCache` (only when
   enabled), `browserUrl`, `maximumMessageSizeBytes`, and `global`. The
   override propagates to both ConfigMaps, so every client (frontend,
   scheduler, workers, browser, remote asset, portal) inherits the mirror,
   and the checksum annotations roll them all when it changes. Overrides are
   inserted **verbatim** (no templating): hardcode the namespace, shard
   addresses, and anything the stock file derives from values, and re-diff
   your fork against `files/config/common.libsonnet` on every chart upgrade.

2. **Ring B** — add a second StatefulSet and headless Service through
   `extraObjects`. Use distinct labels (`app: storage-b`) and a dedicated
   Service copying `publishNotReadyAddresses: true` — per-pod DNS records
   only exist for pods a Service selects, and reusing `app: storage` would
   give two StatefulSets overlapping selectors. `extraObjects` entries are
   tpl-rendered with the chart context, so the pod spec can reuse the chart's
   storage helpers instead of re-deriving the volume logic
   (`buildbarn.storage.volumeClaimTemplates`,
   `buildbarn.storage.podStoreVolumes`, `buildbarn.storage.fsVolumeMounts`,
   `buildbarn.storage.volumeInitScript`,
   `buildbarn.storage.podSecurityContext`) and should mount the
   `buildbarn-config` ConfigMap (`common.libsonnet` + `storage.jsonnet`)
   exactly like the stock StatefulSet — both rings must run identical store
   geometry. Copy the PDB, NetworkPolicy, and VMPodScrape objects for
   `app: storage-b` if you use them; the packaged storage scrape's ordinal
   relabeling maps `storage-b-3` to shard `3` when copied, and
   `kubernetes_replica` then distinguishes the rings.

3. **Optional bb_replicator** — with many clients, client-side (`local`) CAS
   repair can stampede the surviving ring while an empty ring refills. The
   `remote` replicator delegates that work to
   `ghcr.io/buildbarn/bb-replicator` (released in lockstep with
   `images.storage`): one Deployment per direction, each with its own
   ConfigMap and Service via `extraObjects`, admitted to the storage port
   with `storage.networkPolicy.additionalClientPeers`. bb-storage's
   `bb_copy` tool can pre-seed a fresh ring instead of waiting for organic
   refill.

Hazards you own:

- **`persistence.mode: hostPath` (including block devices via hostPath)
  requires hard anti-affinity between the rings.** Both rings render the
  same node-local paths and device nodes, so a ring-A and a ring-B pod on
  the same node open the same files and corrupt the store. Give each ring
  required pod anti-affinity against the other ring's label on
  `kubernetes.io/hostname`, or pin the rings to disjoint node pools. Place
  the rings in separate failure domains regardless — mirroring onto the
  same disks buys nothing.
- Keep the rings symmetric: the same shard count and the same store
  geometry (both mount the same `storage.jsonnet`). Resize only one ring at
  a time.
- Enabling mirroring over an existing loaded cache is safe for ring A (its
  addresses do not change), and ring B refills on the request path — expect
  slow first builds, or pre-seed with `bb_copy`.

## Browser SSO

Browser SSO is separate from frontend gRPC authentication. The Browser can be
protected with an `oauth2-proxy` sidecar:

```yaml
browser:
  oauth2Proxy:
    enabled: true
    existingConfigMap: oauth2-proxy-config-web-ui
    client:
      existingSecret: oauth2-proxy-client
```

When the Hermetiq chart is installed first with dashboard OAuth enabled, this
chart can reuse the dashboard `oauth2-proxy-config-web-ui` ConfigMap and
`oauth2-proxy-client` Secret. The shared ConfigMap provides provider/session
settings. The Buildbarn Browser Deployment supplies its own redirect URL and
upstream through container environment variables.

When enabled, the Browser Service exposes oauth2-proxy on port `80`; oauth2-proxy
redirects to `https://<browser-host>/oauth2/callback` and proxies upstream to the
local Browser container on `127.0.0.1:7984`.

If `browser.oauth2Proxy.existingConfigMap` is empty, the chart renders a
Buildbarn-specific oauth2-proxy ConfigMap. In that mode,
`browser.oauth2Proxy.oidcIssuerUrl` is required.

For production installs that render the Buildbarn-specific ConfigMap, review
the insecure provider and TLS flags before exposing Browser:

```yaml
browser:
  oauth2Proxy:
    existingConfigMap: ""
    insecureOidcAllowUnverifiedEmail: false
    insecureOidcSkipIssuerVerification: false
    sslInsecureSkipVerify: false
    showDebugOnError: false
```

If `browser.oauth2Proxy.client.existingSecret` is empty, the chart renders an
`oauth2-proxy-client` Secret from `clientId`, `clientSecret`, and `cookieSecret`.

### Custom auth sidecar hook

For auth proxies the chart does not model, append your own sidecar and point
the Browser Service at it. The container spec lives entirely in your values
file (it is rendered through `tpl`), and any referenced Secrets must be
pre-created:

```yaml
browser:
  service:
    targetPortOverride: 9191
  extraContainers:
    - name: my-auth-proxy
      image: registry.example.com/my-auth-proxy:latest
      ports:
        - name: proxy
          containerPort: 9191
      env:
        - name: HTTP_PORT
          value: "9191"
        - name: PROXY_PORT
          value: "7984" # forward to the Browser container
      envFrom:
        - secretRef:
            name: my-auth-proxy-secret
```

With `targetPortOverride` set, the Browser Service serves that port (named
`proxy`) and every routing provider follows it automatically. This hook is
mutually exclusive with `browser.oauth2Proxy.enabled`.

## Frontend Authentication And Writes

The frontend gRPC server can run fully open, or it can verify JWTs from a JWKS
file while still allowing unauthenticated CAS reads:

```yaml
frontend:
  jwks:
    enabled: true
    issuer: https://your-tenant.auth0.com/
    audience: https://your-api-identifier
    configMapName: frontend-jwks
    configMapKey: jwks.json
```

When JWKS is enabled, the frontend renders an `any` authentication policy:

- First arm: validate JWT signature and claims from the mounted JWKS file.
- Second arm: `allow: {}` fallback so unauthenticated requests still pass.

JWT-authenticated requests receive private metadata:

```json
{ "private": { "canWriteToCache": true } }
```

CAS reads remain open by default and are intentionally independent of JWT
validation:

- `contentAddressableStorage.getAuthorizer` is always `allow`.
- `contentAddressableStorage.findMissingAuthorizer` is always `allow`.
- Action Cache reads are always `allow`.

Writes and execution are controlled separately:

```yaml
frontend:
  actionCache:
    putAuthorizer:
      mode: requireCanWriteToCache
  contentAddressableStorage:
    putAuthorizer:
      mode: requireCanWriteToCache
  executeAuthorizer:
    mode: requireCanWriteToCache
```

Use `requireCanWriteToCache` when Action Cache writes, CAS uploads, or Execute
calls should require a valid JWT. Keep `allow` only for clusters where another
proxy layer is intentionally handling trust, or where open writes/execution are
acceptable.

The frontend also keeps CAS reads efficient by default:

- CAS `existenceCaching` is enabled when `frontend.readCache.enabled` is false.
- `supportedCompressors: ['ZSTD']` is advertised.
- Action Cache `GetActionResult` and `UpdateActionResult` can add digest trace attributes through `frontend.tracingAttributes.actionCacheDigests.enabled`.

## JWKS ConfigMap Management

Buildbarn reads JWKS from a mounted file. It deliberately does not fetch JWKS
over HTTP at runtime, which avoids a startup dependency on the identity provider
and avoids every frontend/storage pod polling the IdP.

You have two options.

Manage the ConfigMap yourself:

```bash
curl -fsS https://your-tenant.auth0.com/.well-known/jwks.json \
  | kubectl create configmap frontend-jwks \
      --from-file=jwks.json=/dev/stdin \
      --dry-run=client -o yaml \
  | kubectl apply -n hermetiq -f -
```

Or enable the bundled sync:

```yaml
frontend:
  jwks:
    enabled: true
    sync:
      enabled: true
      url: https://your-tenant.auth0.com/.well-known/jwks.json
      schedule: "0 */6 * * *"
      initialSyncEnabled: true
```

The sync path renders a small namespace-scoped ServiceAccount, Role/RoleBinding,
CronJob, and optional post-install/post-upgrade Job using Buildbarn's
`sync_jwks_to_configmap` image. The chart also seeds the ConfigMap with
`{"keys":[]}` so the frontend can mount the volume before the first sync.

The sync workload patches the JWKS ConfigMap through the Kubernetes API, so its
ServiceAccount token remains enabled by default. You can add job guardrails
without changing the auth model:

```yaml
frontend:
  jwks:
    sync:
      startingDeadlineSeconds: 600
      job:
        activeDeadlineSeconds: 300
        ttlSecondsAfterFinished: 3600
      initialJob:
        activeDeadlineSeconds: 300
        ttlSecondsAfterFinished: 3600
```

Rotation flow:

```text
IdP publishes keys -> CronJob patches ConfigMap -> kubelet updates volume -> Buildbarn reloads jwks.json
```

## Tracing, Metrics, And Diagnostics

`common.libsonnet` defines shared Buildbarn globals. When tracing is enabled,
that shared global is used by storage, frontend, scheduler, browser, workers,
runners, and remote asset:

```yaml
tracing:
  enabled: true
  nodeLocal:
    enabled: true
    port: 4317
```

With node-local tracing enabled, each pod exports spans to
`$(K8S_LOCAL_NODE_IP):<port>`. With node-local tracing disabled, set
`tracing.endpoint`.

Optional TLS and mTLS are configured under:

```yaml
tracing:
  tls:
    enabled: true
    clientCertificate:
      enabled: true
```

Containers that use the shared tracing config receive a `SERVICE_NAME`
environment variable. Node-local tracing also injects `K8S_LOCAL_NODE_IP` from
the pod's host IP. These environment variables are required because Jsonnet uses
`std.extVar()`.

The shared global also includes the diagnostics HTTP server on `:9980` with
Prometheus, pprof, and active spans enabled. Worker pods are special: the worker
and runner containers share one pod network namespace, so only the worker should
bind `:9980`. The runner still inherits tracing and other shared global settings,
but its config uses Jsonnet hidden-field override syntax to strip diagnostics:

```jsonnet
global: common.global {
  diagnosticsHttpServer:: null,
}
```

When `vmPodScrapes.enabled` is true, the chart renders VictoriaMetrics
`VMPodScrape` resources for Buildbarn pods and stamps samples with
`hermetiq_project_id`.

When `vmRules.enabled` is true, the chart renders Buildbarn recording rules as
VictoriaMetrics `VMRule` resources. The VMRule namespace defaults to the chart
namespace; set `vmRules.namespaceOverride` if your VictoriaMetrics operator only
watches a dedicated observability namespace. Use `vmRules.labels` when your
`VMAgent` selects rules by label.

Disable the VictoriaMetrics resources on clusters without the VictoriaMetrics
operator CRDs installed:

```yaml
vmPodScrapes:
  enabled: false
vmRules:
  enabled: false
```

## Remote Asset API

The Remote Asset API lets Bazel ask Buildbarn to fetch external assets, such as
HTTP URLs, and store the resulting blob in CAS. This avoids every client or
worker fetching the same external asset independently.

Enable it with:

```yaml
remoteAsset:
  enabled: true
  fetcher:
    http:
      enabled: true
```

The chart renders:

- `asset.jsonnet` in `buildbarn-config`.
- `remote-asset` Deployment.
- `remote-asset` Service.
- `remote-asset-grpc` Service.
- A Contour `HTTPProxy`, Gateway `GRPCRoute`, or nginx-style `Ingress` when the matching route value is enabled.
- `remote-asset-vmpodscrape` when `vmPodScrapes.enabled` is true.

Remote asset health probes are enabled by default when the workload is enabled,
using the shared Buildbarn diagnostics server on `:9980`:

```yaml
remoteAsset:
  probes:
    enabled: true
```

The default `asset.jsonnet` uses the same sharded CAS and Action Cache helpers
as the frontend. It allows Fetch requests and disables Push by default through:

```yaml
remoteAsset:
  allowUpdatesForInstances: []
```

FetchBlob URI tracing is enabled by default:

```yaml
remoteAsset:
  tracingAttributes:
    fetchBlobUris:
      enabled: true
```

For Contour or Ingress, expose it with:

```yaml
remoteAsset:
  enabled: true
ingress:
  remoteAssetGrpc:
    enabled: true
```

For Gateway API, expose it with:

```yaml
remoteAsset:
  enabled: true
gateway:
  grpcRoutes:
    remoteAsset:
      enabled: true
```

## bb-portal

`portal.enabled` deploys the [bb-portal](https://github.com/buildbarn/bb-portal)
build-event dashboard as a single `bb-portal` Deployment. One container serves
everything:

- the web UI and its HTTP/gRPC-Web APIs on `portal.<domainBase>` (`:8081`),
- the Build Event Stream gRPC ingest endpoint on `bes.<domainBase>` (`:8082`,
  h2c), persisting invocations to PostgreSQL,
- diagnostics and Prometheus metrics on `:9980`.

The UI is embedded in the Go binary
(`frontendServiceConfiguration.frontendSource.embedded`), so there is no
separate Next.js workload and nothing to proxy to.

> **bb-portal is unauthenticated.** Both routes are served with
> `authenticationPolicy: { allow: {} }` and an `allow` instance-name authorizer,
> so anyone who can reach `portal.<domainBase>` can read every build's events,
> and anyone who can reach `bes.<domainBase>` can publish their own. The chart
> does not front the portal with oauth2-proxy the way `browser.oauth2Proxy`
> fronts Buildbarn Browser. Before enabling it, put it behind an external auth
> layer, restrict the routes to an internal-only Gateway or Ingress, or limit
> reachability with a NetworkPolicy. Also consider
> `portal.bes.enableGraphqlPlayground: false`.

```yaml
portal:
  enabled: true
  db:
    existingSecret: bbportal-db-env
  frontend:
    companyName: Hermetiq
```

The database Secret must be pre-created with keys `DB_USER`, `DB_PASSWORD`,
`DB_HOSTNAME`, `DB_PORT`, and `DB_NAME`; the pod composes
`DB_CONNECTION_STRING` from them at start. The chart never renders database
credentials. `portal.db.connectionPool` bounds the pool — keep
`maxOpenConnections` within what your server allows across all replicas.

`portal.bes.buildKey` names the build tag that groups invocations into builds,
but build tags only exist if `portal.bes.invocationMetadataExtractor` produces
them. That value is a raw
`buildbarn.configuration.jmespath.Expression` evaluated against
`{"env": <Bazel's environment>, "files": {...}}`, and what it returns is what
populates the Builds page, the per-user views, and the source-control tab:

```yaml
portal:
  bes:
    invocationMetadataExtractor:
      expression: |
        {
          "username": env.BUILDKITE_BUILD_CREATOR,
          "buildTags": {"build_id": env.BUILDKITE_BUILD_ID},
          "sourceControls": [{
            "repo": env.BUILDKITE_REPO,
            "ref": env.BUILDKITE_BRANCH,
            "commit": env.BUILDKITE_COMMIT
          }]
        }
```

With no extractor configured (the default), invocations are still recorded but
never group into builds. `expression` also accepts `files` and `testVectors` —
failing test vectors abort startup, so they are worth adding.

`portal.frontend` holds UI settings only. `featureFlags` toggles pages
(`home.fileUpload`, `home.instructions`, the five `bes.page*` pages, `browser`,
`scheduler`); each one only hides UI, so do not treat them as access control.
Turn `browser` off if you send people to Buildbarn Browser instead.
`footerContent`, `additionalBuildColumns`, and
`additionalBuildInvocationColumns` pass through to the frontend config as-is.

Routes render per provider (Contour `HTTPProxy`, Gateway `HTTPRoute` +
`GRPCRoute`, or nginx `Ingress` pairs), all backed by the single `bb-portal`
Service, and are individually gated by `ingress.portal` / `ingress.besGrpc` /
`gateway.httpRoutes.portal` / `gateway.grpcRoutes.bes`. The Certificate gains
the `portal.` and `bes.` SANs in contour/ingress modes, and a `VMPodScrape`
covers the `:9980` diagnostics port.

Point Bazel at it with:

```
build --bes_backend=grpcs://bes.<domainBase>
build --bes_results_url=https://portal.<domainBase>/bazel-invocations/
```

The portal's blob browsing reads the storage shards directly (top-level
`contentAddressableStorage` / `actionCache`, plus `initialSizeClassCache` and
`fileSystemAccessCache` when those stores are enabled) rather than going through
`frontend-grpc`, so portal traffic never passes the optional grpc-cache-proxy
sidecar and cannot pollute cache-event analytics.
`configOverrides."portal.jsonnet"` replaces the generated config wholesale if
you need settings the values do not expose.

## Worker And Runner

By default this chart does not render the Ubuntu 22.04 worker Deployment. Install
the `bb-worker-operator` chart and create `RbeWorker` custom resources for normal
worker pools.

The legacy `worker-ubuntu22-04` Deployment can still be enabled with
`workerUbuntu2204.enabled=true`. When enabled, it runs two main containers and
two init containers:

| Container | Purpose |
| --- | --- |
| `worker` | Runs `bb_worker`, talks to scheduler/storage, prepares inputs, calls the local runner, uploads outputs. |
| `runner` | Runs `/bb/bb_runner` inside the configured Ubuntu image and executes build commands. |
| `bb-runner-installer` | Copies `bb_runner` into the shared `/bb` volume. New Buildbarn images install only `bb_runner`, not `tini`. |
| `volume-init` | Creates `/worker/build`, `/worker/cache`, and `/storage-worker-cas/persistent_state` with the expected permissions. |

The runner command is intentionally direct:

```yaml
command:
  - /bb/bb_runner
  - /config/runner-ubuntu22-04.jsonnet
```

Older manifests used `/bb/tini -v -- /bb/bb_runner ...`; that no longer works
with current `bb-runner-installer` images because `tini` is not installed.

The worker and runner communicate over a Unix socket:

```text
unix:///worker/runner
```

The `worker` volume is an `emptyDir` shared by both containers. The worker uses
`Bidirectional` mount propagation and the runner uses `HostToContainer` so FUSE
mounts created by the worker are visible to the runner.

The legacy worker also mounts:

- `/dev/fuse` from the host when `workerUbuntu2204.fuse.enabled` is true.
- `/storage-worker-cas` from a host path, usually backed by local SSD.
- `/config` from `buildbarn-worker-config`.

Key worker config values:

```yaml
workerUbuntu2204:
  config:
    concurrency: 11
    inputDownloadConcurrency: 9
    outputUploadConcurrency: 11
    platformProperties:
      - name: container-image
        value: docker://ghcr.io/catthehacker/ubuntu:act-22.04
```

Bazel selects this worker pool by sending matching remote execution platform
properties, for example through `--remote_default_exec_properties`.

The worker advertises a stable worker ID using downward API ext vars:

- `POD_NAME`
- `NODE_NAME`

Completed action logging is enabled by default and sends action completion data
to `bbcal.address`.

## Worker Autoscaling

When `keda.enabled` and `workerUbuntu2204.enabled` are true, the chart renders a
KEDA `ScaledObject` for `worker-ubuntu22-04`. The scaler queries VictoriaMetrics
for scheduled tasks minus tasks that have finished execution, which tracks
currently queued or executing work for the worker platform properties.

Operator-managed worker autoscaling should be configured on the `RbeWorker` custom
resource instead. Leaving `workerUbuntu2204.enabled=false` also disables the old
chart-managed `ScaledObject`.

The chart still renders the shared `worker-vmpodscrape` when
`vmPodScrapes.enabled=true`. Preserve the `app=worker` pod label, or update your
own scrape configuration, so operator-managed worker metrics continue to be
collected.

Important values:

```yaml
keda:
  enabled: true
  prometheusServerAddress: http://vmselect-vmks.hermetiq.svc.cluster.local:8481/select/0/prometheus
  workerUbuntu2204:
    minReplicaCount: 0
    maxReplicaCount: 20
    threshold: "11"
```

With KEDA enabled, the Deployment does not render a static `replicas` field.
With KEDA disabled, `workerUbuntu2204.replicas` controls the Deployment directly.

## Testcontainers Worker Fleets

The chart includes two optional worker fleets for Bazel tests that need a
Docker daemon at action-execution time (Testcontainers, container-image tests,
etc.). Both are disabled by default and can run side by side:

- `workerTestcontainers`: Docker-in-Docker sidecar, routed with `pool=testcontainers`.
- `workerTestcontainersSysbox`: Docker inside a Sysbox runner container, routed with `pool=testcontainers-sysbox`.

At a high level, both fleets present the same Docker API to the action:
`DOCKER_HOST=unix:///var/run/docker.sock`,
`TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE=/var/run/docker.sock`, and
`TESTCONTAINERS_HOST_OVERRIDE=localhost`. The difference is where that daemon
comes from. DinD runs a privileged `docker:dind` sidecar and shares its socket
with the runner. Sysbox starts `dockerd` inside the runner container itself,
under Kubernetes `runtimeClassName: sysbox-runc` and `hostUsers: false`, so it
does not need a privileged Docker sidecar or a host Docker socket.

The sample Bazel workspace in the repository's
[`examples/testcontainers/`](https://github.com/Hermetiq/hermetiq-k8s/tree/main/examples/testcontainers)
directory demonstrates the target-side pattern: declare the Testcontainers environment variables on the
test rule and select a worker fleet with `exec_properties`.

Enable the DinD fleet with:

```yaml
workerTestcontainers:
  enabled: true
```

Enable the Sysbox fleet with:

```yaml
images:
  runnerTestcontainersSysbox:
    image: <registry>/buildbarn-sysbox-runner:latest
    pullPolicy: Always
workerTestcontainersSysbox:
  enabled: true
```

### DinD Fleet

When `workerTestcontainers.enabled` is true, the chart renders a
`worker-testcontainers` Deployment whose pod runs three containers — `worker`,
`runner`, and a `dind` (Docker-in-Docker) sidecar — plus a matching KEDA
`ScaledObject`. The `dind` sidecar runs
`dockerd` against a shared `emptyDir` `/var/run/docker.sock`, which the
`runner` container mounts so actions (and the Testcontainers client) can
reach the daemon at `unix:///var/run/docker.sock`. The runner waits for the
socket before starting `bb_runner`; test targets should still set the
Testcontainers environment variables directly, as shown below, because Bazel's
test wrapper does not preserve all worker-injected environment variables.

### Sysbox Fleet

When `workerTestcontainersSysbox.enabled` is true, the chart renders a separate
`worker-testcontainers-sysbox` Deployment whose pod runs only `worker` and
`runner` containers under `runtimeClassName: sysbox-runc`. It does not render a
DinD sidecar, does not mount the host Docker socket, and does not share a
`/var/run` Docker socket volume. The Sysbox runner image is responsible for
including `/bb/bb_runner` and starting `dockerd` inside the runner container
before launching `bb_runner`; unlike the regular worker fleets, the Sysbox fleet
does not use a `bb-runner-installer` init container because the runtime class is
applied to the whole pod.

The chart does not build or publish that image. See the repository's
[`examples/sysbox-runner-image/`](https://github.com/Hermetiq/hermetiq-k8s/tree/main/examples/sysbox-runner-image)
for a Dockerfile and entrypoint adapted from EngFlow's Sysbox recommendation.

The example image does three chart-specific things:

- Installs Docker Engine and CLI.
- Copies Buildbarn's `bb_runner` into `/bb` at image build time.
- Starts `dockerd`, waits for `docker info`, optionally pre-pulls images from
  `workerTestcontainersSysbox.preloadImages`, then execs `bb_runner`.

Avoid application env vars with the `SYSBOX_` prefix in Sysbox pods. Sysbox
reserves that prefix for runtime directives and rejects unknown names before the
container starts.

### Routing

The DinD fleet advertises platform property `pool=testcontainers`; the Sysbox
fleet advertises `pool=testcontainers-sysbox`. Keep the default operator-managed
worker pool or legacy `workerUbuntu2204` fleet without a `pool` property, so:

- Actions that do not request `pool` continue to route to the default worker pool.
- Actions that request `pool=testcontainers` route only to the DinD fleet.
- Actions that request `pool=testcontainers-sysbox` route only to the Sysbox fleet.

Buildbarn's default action platform matching is exact: the action's platform
properties must equal the worker's advertised platform properties. The most
direct way to route a Testcontainers test is to set `exec_properties` on the
target:

```starlark
go_test(
    name = "integration_test",
    env = {
        "DOCKER_HOST": "unix:///var/run/docker.sock",
        "TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE": "/var/run/docker.sock",
        "TESTCONTAINERS_HOST_OVERRIDE": "localhost",
    },
    exec_properties = {
        "pool": "testcontainers",
    },
    tags = ["requires-docker"],  # informational; not used for routing
    ...
)
```

For Sysbox, use `pool=testcontainers-sysbox` instead.

Both fleets use the same Testcontainers environment variables in the Bazel
target because Testcontainers should connect to the Docker daemon from inside
the action container, not to a node-level Docker socket.

If you keep additional worker platform properties such as `container-image`,
make sure the action requests those properties too, for example via
`--remote_default_exec_properties`. Do not rely on
`--modify_execution_info=.*@requires-docker=+pool=testcontainers` for tag-based
routing; Bazel matches that flag against action mnemonics, not target tags.

### Node Pool Prerequisites

The chart does not create node pools — provision them out-of-band.

The DinD pool must satisfy:

- Label `workload=testcontainers` (matched by `workerTestcontainers.nodeSelector`)
- Taint `workload=testcontainers:NoSchedule` (tolerated by `workerTestcontainers.tolerations`)
- Ubuntu containerd node image — `dind`'s `overlay2` storage driver needs the
  kernel `overlay` module, which is available on GKE Ubuntu nodes. Container-Optimized
  OS (`cos_containerd`) is too locked down for the privileged `dind` sidecar.
- Local SSD mounted at `/mnt/stateful_partition/kube-ephemeral-ssd` for the
  CAS hostPath (same convention used by `worker-ubuntu22-04`).
- A machine type with memory headroom for the pod (default Pod limit is 32Gi
  for the runner alone; plan for ≥64Gi nodes to leave room for two pods plus
  system overhead).

The Sysbox pool must satisfy:

- Label `workload=testcontainers-sysbox` (matched by `workerTestcontainersSysbox.nodeSelector`)
- Taint `workload=testcontainers-sysbox:NoSchedule` (tolerated by `workerTestcontainersSysbox.tolerations`)
- Sysbox installed on every node in the pool.
- Kubernetes `RuntimeClass` named `sysbox-runc` with handler `sysbox-runc`.
- Kubernetes user namespaces enabled for Sysbox pods. The chart renders
  `hostUsers: false` for `workerTestcontainersSysbox` by default.
- When using Kubernetes 1.33+ with containerd 2, Sysbox v0.7 requires
  containerd 2.0.5 or newer; GKE 1.33 node images may lag that patch level.
- A reachable image configured at `images.runnerTestcontainersSysbox.image`.
- Local SSD mounted at `/mnt/stateful_partition/kube-ephemeral-ssd` for the CAS hostPath.

Useful smoke checks after deploying Sysbox:

```bash
kubectl get nodes \
  -l workload=testcontainers-sysbox \
  -L sysbox-install,sysbox-runtime,workload

kubectl run sysbox-smoke \
  --image=ubuntu:22.04 \
  --restart=Never \
  --overrides='{"spec":{"runtimeClassName":"sysbox-runc","hostUsers":false,"nodeSelector":{"workload":"testcontainers-sysbox"},"tolerations":[{"key":"workload","operator":"Equal","value":"testcontainers-sysbox","effect":"NoSchedule"}],"containers":[{"name":"sysbox-smoke","image":"ubuntu:22.04","command":["sleep","3600"]}]}}'

kubectl -n hermetiq exec -it deploy/worker-testcontainers-sysbox -c runner -- docker info
```

### Operational notes

- `dind` runs `privileged: true` — required for cgroup, netns, and overlay
  mount management. The trust boundary is the same as `workerUbuntu2204`,
  which also runs the worker container privileged for FUSE.
- Sysbox does not use the DinD sidecar, host Docker socket, or Docker
  privileged mode. Docker runs inside the Sysbox runner container.
- Image pulls happen inside the `dind` daemon, not on the node, so the node-
  level image cache does not warm them. Populate `workerTestcontainers.preloadImages`
  or `workerTestcontainersSysbox.preloadImages` with frequently used images
  (e.g. `postgres:16`, `redis:7`) so they are pulled once at pod start.
  Add a registry mirror to `workerTestcontainers.dind.registryMirrors` for DinD
  or bake mirror config into the Sysbox runner image.
- **Future work — node-level image cache DaemonSet.** `preloadImages` pulls
  into each pod's emptyDir, which dies with the pod; a pod restart (OOM,
  eviction, KEDA scale-up after scale-down, rolling chart upgrade) re-pulls
  every image from the registry. A DaemonSet that pulls images on each
  testcontainers node and writes them as tarballs to a hostPath on Local SSD
  would let DinD sidecars `docker load` on startup instead of re-pulling —
  roughly 10× faster pod recovery, plus resilience to registry outages and
  rate limits. Deferred until a real customer hits the cold-cache pain
  point; per-pod `preloadImages` is sufficient at small fleet size.
- These actions will not cache meaningfully in the action cache. The container
  runtime state is not part of the action digest. Expect ~0% cache-hit rate
  on this fleet.
- Ryuk (the Testcontainers reaper) is left enabled by default. If you pre-pull
  the Ryuk image, include the tag that matches your Testcontainers client
  versions.

## Security And Availability Hardening

The chart preserves existing Kubernetes defaults unless you opt in. To stop
application and chart-managed worker pods from receiving default ServiceAccount
tokens, set a global default and keep JWKS sync enabled only when that feature
is in use:

```yaml
serviceAccount:
  automountServiceAccountToken: false

frontend:
  jwks:
    sync:
      # Required when frontend.jwks.sync.enabled=true because the sync Job
      # patches the JWKS ConfigMap through Kubernetes RBAC.
      automountServiceAccountToken: true
```

Workloads can override the global setting with their own
`automountServiceAccountToken` value: `storage`, `frontend`, `scheduler`,
`browser`, `remoteAsset`, `workerUbuntu2204`, `workerTestcontainers`, and
`workerTestcontainersSysbox`.

PodDisruptionBudgets are disabled by default so single-replica installs and
node drains keep existing behavior. Enable them after replica counts are high
enough for the selected availability policy:

```yaml
storage:
  podDisruptionBudget:
    enabled: true
    maxUnavailable: 1

frontend:
  replicas: 2
  podDisruptionBudget:
    enabled: true
    maxUnavailable: 1
```

Use frontend JWKS plus `requireCanWriteToCache` authorizers for exposed
frontend gRPC endpoints. Leaving write and execute authorizers as `allow` is
appropriate only when another trusted layer is enforcing access.

### Restricting direct storage access

The storage shards serve unauthenticated gRPC on `:8981`. That port is the CAS
and Action Cache themselves, so anything able to reach it can read and write
cache entries directly; the frontend authorizers are not a boundary for traffic
that bypasses the frontend. The port is never routed externally, so the
exposure is in-cluster: by default any pod in the cluster can reach it.

`storage.networkPolicy` restricts it to the Buildbarn components plus peers you
name. It is disabled by default because it has to know where your workers run:

```yaml
storage:
  networkPolicy:
    enabled: true
    # Operator-managed RbeWorker pods outside the Buildbarn namespace.
    additionalClientPeers:
      - podSelector:
          matchLabels:
            app.kubernetes.io/name: bb-worker
        namespaceSelector:
          matchLabels:
            kubernetes.io/metadata.name: rbe-workers
    # Peers allowed to scrape metrics on :9980. An empty list allows any
    # source, which suits a scraper that runs in another namespace.
    metricsPeers:
      - namespaceSelector:
          matchLabels:
            kubernetes.io/metadata.name: victoriametrics
```

Enable this only after enumerating every client. Workers, the frontend, the
scheduler, Browser, the portal, and the remote asset service all talk to
storage directly, and a missing peer surfaces as cache misses and RBE failures
rather than a clear connection error. The cluster also needs a
NetworkPolicy-enforcing CNI; without one the policy is accepted and silently
does nothing.

## Scheduling

Non-worker pods inherit top-level scheduling by default:

```yaml
k8sNodeScheduling:
  nodeSelector:
    kubernetes.io/arch: amd64
    kubernetes.io/os: linux
  tolerations: []
```

This applies to browser, frontend, scheduler, storage, and remote asset. Set
`nodeSelector` or `tolerations` under an individual workload to override it:

```yaml
frontend:
  nodeSelector:
    kubernetes.io/arch: amd64
    kubernetes.io/os: linux
    node-type: core8
  tolerations:
    - effect: NoSchedule
      key: hermetiq/core8
      operator: Exists
```

Operator-managed workers use scheduling fields on their `RbeWorker` custom
resources. Legacy chart-managed workers use `workerUbuntu2204.nodeSelector` and
`workerUbuntu2204.tolerations`, because worker scheduling usually targets larger
or local-SSD nodes. Override these for your cloud provider and node pool.

## Verification

Render and inspect the chart:

```bash
helm template buildbarn oci://ghcr.io/hermetiq/buildbarn \
  --version 0.9.0 \
  --namespace hermetiq \
  --values buildbarn-values.yaml > /tmp/buildbarn.yaml
```

Check workloads:

```bash
kubectl get deploy browser frontend scheduler-ubuntu22-04 -n hermetiq
kubectl get sts storage -n hermetiq
kubectl get rbeworkers.bb.hermetiq.com -n hermetiq
```

Legacy chart-managed workers may be `0/0` until KEDA scales them for queued
work. Operator-managed worker status is reported on the `RbeWorker` custom
resource.

Check endpoints:

```bash
kubectl get endpoints browser frontend-grpc scheduler storage -n hermetiq
```

If bb-portal is enabled, also check:

```bash
kubectl get endpoints bb-portal -n hermetiq
```

If Remote Asset API is enabled, also check:

```bash
kubectl get endpoints remote-asset remote-asset-grpc -n hermetiq
```

Inspect routes for your provider:

```bash
kubectl get httpproxy -n hermetiq
kubectl get httproute,grpcroute -n hermetiq
kubectl get httproute,healthcheckpolicy,gcpbackendpolicy -n hermetiq
kubectl get ingress -n hermetiq
```

If VictoriaMetrics resources are enabled, check scrapes and recording rules:

```bash
kubectl get vmpodscrape,vmrule -n hermetiq
```

Inspect an operator-managed worker pool through its `RbeWorker` status, which
records the managed Deployment name and the pod selector:

```bash
kubectl -n hermetiq describe rbeworker worker-ubuntu22-04

SELECTOR=$(kubectl -n hermetiq get rbeworker worker-ubuntu22-04 \
  -o jsonpath='{.status.selector}')
DEPLOY=$(kubectl -n hermetiq get rbeworker worker-ubuntu22-04 \
  -o jsonpath='{.status.deploymentName}')

kubectl -n hermetiq get pods -l "$SELECTOR"
kubectl -n hermetiq logs deploy/"$DEPLOY" -c worker
kubectl -n hermetiq logs deploy/"$DEPLOY" -c runner
```

Inspect legacy chart-managed worker startup issues:

```bash
kubectl describe pod -l app=worker,instance=ubuntu22-04 -n hermetiq
kubectl get deploy -l app=worker -n hermetiq
kubectl logs deploy/worker-ubuntu22-04 -c worker -n hermetiq
kubectl logs deploy/worker-ubuntu22-04 -c runner -n hermetiq
```

Confirm the frontend accepts your JWT and advertises remote execution and
Action Cache writes:

```bash
export JWT="..."

grpcurl -H "authorization: Bearer $JWT" -d @ \
  bb.<your-domain>:443 \
  build.bazel.remote.execution.v2.Capabilities/GetCapabilities \
  <<<'{"instance_name":"0"}' | jq '.executionCapabilities.execEnabled'

grpcurl -H "authorization: Bearer $JWT" -d @ \
  bb.<your-domain>:443 \
  build.bazel.remote.execution.v2.Capabilities/GetCapabilities \
  <<<'{"instance_name":"0"}' | jq '.cacheCapabilities.actionCacheUpdateCapabilities'
```

Expect `true` for `execEnabled` and `{"updateEnabled": true}` for the Action
Cache. Use the Hermetiq project ID as the instance name so the grpc-cache-proxy
sidecar, when enabled, attributes the lookups to that project.

## Hermetiq grpc-cache-proxy sidecar

> **Experimental.** Treat the sidecar as an advanced option. Install Hermetiq
> and Buildbarn first, complete both charts' verification steps, and confirm
> that builds run successfully against the remote cache before enabling it.
> Enabling it moves the `frontend-grpc` Service's target port to the sidecar,
> so treat it as a separate, deliberately verified change.

`frontend.grpcCacheProxy` adds a Hermetiq sidecar that observes frontend gRPC
traffic and publishes cache hit/miss events to NATS for Hermetiq analytics:

```yaml
frontend:
  grpcCacheProxy:
    enabled: true
    natsUrl: nats://nats.nats-system.svc:4222
    cacheEvents:
      subjectPrefix: prod_cache
      numShards: 1
```

When enabled, the `frontend-grpc` Service keeps port `8980` but its
`targetPort` switches to the sidecar (`frontend.grpcCacheProxy.port`, default
`50081`), so all routing providers pass external traffic through the proxy
with no route changes; the sidecar forwards to the frontend container on
`127.0.0.1:8980`. `stytch.existingSecret` (default `stytch-secret`) is exposed
via `envFrom` for token validation — only when `enforceAuth` is true, since the
proxy reads the `STYTCH_*` vars only then.

The sidecar's exporter is always configured, so the chart always sets
`OTEL_EXPORTER_OTLP_ENDPOINT` (otherwise the OTEL SDK would dial its default of
`localhost:4317`). It resolves in this order:

1. `frontend.grpcCacheProxy.otel.endpoint`, used verbatim if set.
2. `tracing.enabled` and `tracing.nodeLocal.enabled` — the node-local agent at
   `$(K8S_LOCAL_NODE_IP):<tracing.nodeLocal.port>`.
3. `tracing.enabled` and `tracing.endpoint` — that endpoint.
4. Otherwise `http://<hosts.otel>:4317`. `hosts.otel` is required here.

Cases 2 and 3 use `https` when `tracing.tls.enabled` is set, `http` otherwise.
Case 4 is always plaintext, and `hosts.otel` defaults to a Hermetiq-operated
host — point it at your own in-cluster collector for on-prem installs, or set
`frontend.grpcCacheProxy.otel.endpoint` explicitly. Note the sidecar mounts no
client certificates, so `tracing.tls.clientCertificate` (mTLS) does not reach
it; use `otel.endpoint` with a collector that does not require mTLS.

`cacheEvents.numShards` **must** equal the bep-nats stream partition count on the
Hermetiq side. Events published to a shard subject nothing consumes are silently
discarded.

`maxMessageSizeBytes` (default 64Mi) applies to both the sidecar's server and its
connection to the frontend, and is floored at `config.maximumMessageSizeBytes` so
the sidecar can never be a smaller bottleneck than the frontend behind it.

Because the Service `targetPort` moves to the sidecar, gRPC health checks on that
port (`frontend.grpcCacheProxy.probes`, native Kubernetes gRPC probes) report the
*proxy's* health, not the frontend's. The frontend container keeps its own HTTP
probes on `:9980`.

`enforceAuth: false` makes the sidecar a pure forwarder — it is **not** an
authorization boundary in that mode, and Buildbarn's own authorizers remain the
only thing gating access.

For trusted in-cluster clients that cannot authenticate to the proxy, keep
`enforceAuth: true` on the externally routed `frontend-grpc` Service and enable
the separate direct Service instead:

```yaml
frontend:
  internalService:
    enabled: true
    name: frontend-internal
```

This creates the ClusterIP endpoint
`frontend-internal.<namespace>.svc.cluster.local:8980`. It always targets the
Buildbarn frontend container on port `8980`, while `frontend-grpc` continues to
target the proxy sidecar. The internal Service bypasses proxy authentication and
cache-event capture, so never attach an Ingress, Gateway route, or other external
load balancer to it. Use a NetworkPolicy if only selected namespaces should be
able to reach the direct frontend port.

Leave `natsUrl` empty to switch cache-event capture off entirely and run the
sidecar as a plain pass-through proxy. Only unauthenticated NATS endpoints are
supported: there are no values for NATS credentials, nkeys, or TLS.

Tuning beyond the modelled values goes through `frontend.grpcCacheProxy.env`, e.g.
`CACHE_EVENT_BATCH_SIZE`, `CACHE_EVENT_FLUSH_INTERVAL`, `SHUTDOWN_DRAIN_DELAY`,
`SHUTDOWN_TIMEOUT`.

### How lookups are classified

The proxy never inspects stored data. It classifies each `GetActionResult`
purely by the gRPC status the frontend returns:

| Status from the frontend | Recorded as |
| --- | --- |
| `OK` | cache hit |
| `NotFound` | cache miss |
| anything else | no event; the lookup is skipped silently |

Any frontend configuration that turns a cache lookup into some other error
makes those lookups vanish from analytics rather than count as misses. The
chart's generated Jsonnet already satisfies the requirements below; they matter
when you replace `frontend.jsonnet` through `configOverrides`:

- **Keep the frontend listening on `:8980`.** The sidecar forwards to
  `127.0.0.1:8980`. Because the Service `targetPort` points at the sidecar,
  changing `grpcServers[].listenAddresses` takes the whole frontend endpoint
  down.
- **Keep Action Cache reads open.** `actionCache.getAuthorizer` must allow the
  traffic, which is why
  [Frontend Authentication And Writes](#frontend-authentication-and-writes)
  only tightens the put and execute authorizers. A denied read returns
  `PermissionDenied` and produces no event, and the same applies to a request
  rejected as `Unauthenticated` by `grpcServers[].authenticationPolicy`.
- **Keep `completenessChecking` on the Action Cache.** It returns `NotFound`
  when an `ActionResult` exists but its output blobs are gone from the CAS,
  which is what Bazel experiences. Without it those lookups are recorded as
  hits while Bazel treats them as misses, inflating the hit rate exactly when
  CAS eviction pressure is worst.
- **Short Action Cache deadlines hide lookups.** A `deadlineEnforcing` wrapper
  returns `DeadlineExceeded` when storage is slow, and those lookups produce no
  event. A dip in recorded lookups during a storage slowdown reflects the
  timeout, not lost traffic.
- **`actionResultExpiring` is safe.** Expired entries return `NotFound` and are
  recorded as misses, matching what Bazel sees.

### Project attribution

Attribution to a Hermetiq project comes from the request, not from Buildbarn.
With `enforceAuth: false` the proxy reads the `x-hermetiq-project-id` header if
present and otherwise falls back to Bazel's `--remote_instance_name`. Set
`--remote_instance_name` to the Hermetiq project ID unless you send the header.
Buildbarn accepts any instance name here because the chart's blobstore does not
demultiplex on it, but with remote execution the name must still satisfy the
scheduler's `instanceNamePrefix`, which is empty by default and matches
everything. Lookups whose project cannot be resolved are counted as
`unresolved` in the sidecar's log summary.

The scheduler stanza that forwards
`build.bazel.remote.execution.v2.requestmetadata-bin` to the scheduler belongs
to remote execution attribution through the Completed Action Logger, not to the
cache proxy. `GetActionResult` never reaches the scheduler, and the sidecar
reads Bazel's request metadata directly off the incoming request.

### Hermetiq side

Enabling the sidecar collects the events; the Hermetiq chart consumes them. Set
`app.cacheEventsEnabled: true` there, keep the sidecar's `cacheEvents.numShards`
equal to the Hermetiq chart's `app.streamPartitionCount`, and enable
**Action Cache Hit Tracker** in the project's settings.

### Verify the sidecar

```bash
kubectl -n hermetiq get pods -l app=frontend
kubectl -n hermetiq logs -l app=frontend -c grpc-cache-proxy --tail=20
```

Each frontend pod should report `2/2` ready. The proxy logs a one-line
publisher summary each minute rather than per request. `published` climbing
after a build means events are reaching NATS. A high `unresolved` count means
no Hermetiq project could be attributed, which normally means
`--remote_instance_name` does not match a project ID. `dropped` counts events
discarded because NATS was unreachable or slow; cache traffic itself is never
blocked by the event path, so a nonzero `dropped` costs analytics, never
builds. Then run a build and confirm the events appear in the Hermetiq
dashboard's cache analytics or through the Hermetiq MCP server.

## License

The chart source in this package is licensed under the Apache License 2.0;
see the packaged `LICENSE` file. The Buildbarn images it deploys from
`ghcr.io/buildbarn` are Apache-2.0 open source maintained by the Buildbarn
project. The optional Hermetiq grpc-cache-proxy sidecar image is proprietary
software distributed under the
[Hermetiq Software License Agreement](https://github.com/Hermetiq/hermetiq-k8s/blob/main/charts/hermetiq/SOFTWARE-LICENSE-AGREEMENT.md).
