# RBE worker manifests

This directory is a Kustomize base for the standard Ubuntu, Codex, and Envoy
worker pools. After copying `custom-values/` to `my-custom-values/` and
entering the copied directory, edit the manifests for your environment. Apply
them in the Buildbarn release namespace after the Buildbarn release and
`buildbarn-worker-config` are ready. The example release namespace is
`hermetiq`.

These manifests require bb-worker-operator v0.3.14 or later and its matching
CRD (operator chart 0.3.13 or later), which support Buildbarn image inheritance,
the FUSE kernel tunables, and Envoy's `spec.autoscaling.idleReplicas`.
Upgrade the CRD and controller together following the
[CRD lifecycle guide](../../charts/bb-worker-operator/README.md#crd-lifecycle).
FUSE-backed pools also need Linux 6.2 or newer and writable `/sys`; see
[FUSE kernel tuning](#fuse-kernel-tuning) for prerequisites and the fallback.
When upgrading from operator versions before 0.3.4, drop
`spec.autoscaling.prometheus.projectID` from existing manifests and overlays;
queue-depth queries now filter by the worker's namespace.

```bash
kubectl apply --namespace hermetiq --kustomize rbeworkers
```

The manifests do not set `spec.images.worker` or `spec.images.runnerInstaller`.
Operator v0.3.14 and later (chart 0.3.13) then use the `workerImage` and
`runnerInstallerImage` that the Buildbarn chart publishes in
`buildbarn-worker-config`, so each pool's `bb-worker` always matches the
Buildbarn release and its worker configuration. Set them only to run a
different build, and update them in the same change as every Buildbarn
upgrade.

For an existing pre-CDC installation, upgrade the CRD and operator first while
keeping the existing image pins. Its older `buildbarn-worker-config` lacks the
two image keys: populate them with the exact current worker and runner-installer
images before applying these unpinned examples. Verify the pools reconcile,
then upgrade Buildbarn so the shared Jsonnet and inherited images switch to
CDC together. Otherwise the operator reports `SpecInvalid` during the gap.
See the [operator upgrade procedure](../../charts/bb-worker-operator/README.md#upgrading-to-0313).

Custom pools using `spec.config.files` reference a ConfigMap through
`configMapName`, `workerConfigPath`, `runnerConfigPath`, and optional `items`.
The Buildbarn upgrade checks the referenced ConfigMap's selected source keys,
regardless of its name or labels. A ConfigMap that no `RbeWorker` references
is scanned too, with all of its keys, when its name ends in `-worker-config`
or it carries the `hermetiq.com/worker-pool` label and the operator does not
own it. Rename a backup copy of an old worker configuration, or keep it in
another namespace. Generated pools using a custom
`commonConfigMapName`/`commonItems` must also migrate those selected libraries.
Only the Buildbarn chart's own ConfigMaps are exempt because the upgrade
replaces their contents. ConfigMap image defaults must also be CDC-capable;
removing a CR image pin does not update a separate custom ConfigMap. The image
check reads the upstream date stamp in the tag. It cannot classify a
digest-only or re-tagged image, so such a pin passes whatever it runs: check
those yourself.

## Pools

Standard bundle:

- `worker-ubuntu22-04.yaml`: general-purpose Ubuntu 22.04 pool advertising the
  `container-image` platform property most Bazel clients already request.
- `worker-ubuntu24-04.yaml`: the same pool built on Ubuntu 24.04.
- `worker-codex.yaml`: Codex pool using a codex-bazel runner image and a FUSE
  virtual build directory.
- `worker-envoy.yaml`: Envoy CI pool whose runner provides the Envoy build
  toolchain.

Optional components under `optional/`:

- `sizeclass/`: `worker-sizeclass-small.yaml` and `worker-sizeclass-large.yaml`
  advertise the same `pool=sizeclass` platform with different `sizeClass`
  values for ISCC-driven routing.
- `testcontainers/`: Docker-in-Docker pool selected with `pool=testcontainers`.
- `testcontainers-sysbox/`: Sysbox-backed Docker pool selected with
  `pool=testcontainers-sysbox`.
- `drake/`: runner pool for building Drake remotely; publish
  [`examples/drake-runner-image`](../../examples/drake-runner-image/README.md)
  first.

Every manifest references the `buildbarn-worker-config` ConfigMap rendered by
the Buildbarn chart. Pools that should emit completed-action events must point
`spec.config.generated.completedActionLoggerAddress` at the Hermetiq publisher;
the starter value `bep-nats-pub.hermetiq.svc.cluster.local:50091` matches
`bbcal.address` in `custom-values/buildbarn-values.yaml`. Adjust platform
properties and runner images for your workloads.

## Shared worker tuning

The worker manifests carry the shared production tuning. Use an environment
overlay to override those defaults. Namespaces, service addresses,
node-pool selectors, taints, local disk paths, private images, and custom
platform identities remain environment-specific; optional pools remain opt-in.

| Pool | Concurrency | Queue target per replica | Minimum / maximum replicas |
|---|---:|---:|---:|
| Ubuntu 22.04 | 11 | 11 | 0 / 20 |
| Ubuntu 24.04 | 16 | 8 | 1 / 8 |
| Codex | 9 | 9 | 0 / 20 |
| Envoy | 16 | 16 | 4 active, 0 idle / 14 |
| Size class small | 24 | 16 | 3 / 20 |
| Size class large | 12 | 8 | 2 / 20 |
| Testcontainers (DinD) | 4 | 2 | 1 / 6 |
| Drake | 11 | 11 | 0 / 20 |

The queue target is `spec.autoscaling.prometheus.threshold`. Several pools
intentionally target fewer tasks than their execution concurrency. Scale-up
policies use 30-second periods, with pool-specific step sizes and scale-down
behavior; Envoy uses a one-minute query window and a 300-second scale-down
hold before a single 100% step, inside its 450-second KEDA cooldown. The Sysbox
example retains its separate concurrency-2 configuration. Set the warm pools'
minimum to zero in your overlay when using the
[scale-up-from-zero setup](#scale-up-from-zero).

Envoy uses `minReplicas: 4` with `idleReplicas: 0`: KEDA activates four workers
when work arrives and returns the pool to zero after its idle cooldown. Keep
the positive active minimum when using `idleReplicas`. Its worker requests and
limits are 2 CPU / 9Gi memory, and its runner requests and limits are
12 CPU / 46Gi memory, for a combined 14 CPU / 55Gi per Pod. Size the nodes for
these requests plus system overhead. The two size-class pools keep three small
and two large workers warm; lower those minimums for smaller installations.

## Scale-up from zero

Declare every zero-capable worker platform in the Buildbarn chart's
`scheduler.predeclaredPlatformQueues`. The scheduler can then accept actions
for that platform before any workers have registered, giving KEDA queued work
to react to. These logical queues remain available with no workers and are
recreated when the scheduler starts.

Without a declaration, a platform is unknown after a cold scheduler start;
an existing queue is also removed after `scheduler.platformQueueWithNoWorkersTimeout`
(900 seconds by default) without workers. Matching actions are rejected before
they contribute to the queue-depth metric. KEDA sees zero work, so its scaler
failure fallback does not wake the pool.

Add declarations to your **Buildbarn Helm values**, alongside the installed
worker pools. This example covers size-class workers, Codex, Envoy,
Testcontainers, and an Ubuntu 24.04 CI platform:

```yaml
scheduler:
  predeclaredPlatformQueues:
    - platform:
        - { name: pool, value: sizeclass }
      sizeClasses: [1, 2]
    - platform:
        - { name: Arch, value: amd64 }
        - { name: OSFamily, value: Linux }
        - { name: container-image, value: "docker://docker.io/mbolin491/codex-bazel@sha256:0a8e56bfaa3b2e5279db0d3bb2d62b44ba5e5d63a37d97eb8790f49da570af70" }
      sizeClasses: [0]
    - platform:
        - { name: container-image, value: "docker://gcr.io/envoy-ci/envoy-build@sha256:7d3c99085fa5f1cff6b7293de256cc6c93ce61cd7ccb63432113a1f8fbf12a43" }
        - { name: dockerAddCapabilities, value: "SYS_PTRACE,NET_RAW,NET_ADMIN" }
        - { name: dockerNetwork, value: standard }
        - { name: dockerPrivileged, value: "True" }
      sizeClasses: [0]
    - platform:
        - { name: pool, value: testcontainers }
      sizeClasses: [0]
    - platform:
        - { name: env, value: ubuntu2404-62d572b92f9f }
        - { name: pool, value: hmq-ci }
      sizeClasses: [0]
```

Install the optional `sizeclass` and `testcontainers` components through your
[environment overlay](#environment-overlays) for those declarations. Enable
`storage.persistence.iscc.enabled` and `scheduler.sizeClassAnalysis.enabled`
for feedback-driven routing between the two size classes, following the
[ISCC runbook](../../docs/iscc-size-classes.md). The
`hmq-ci` entry assumes an overlay changes `worker-ubuntu24-04` to advertise
exactly these properties:

```yaml
spec:
  config:
    generated:
      platformProperties:
        - { name: env, value: ubuntu2404-62d572b92f9f }
        - { name: pool, value: hmq-ci }
```

The standard Ubuntu 24.04 example advertises
`container-image=docker://ghcr.io/catthehacker/ubuntu:act-24.04`. If you retain
that platform, declare its `container-image` queue instead. Add declarations
for every other installed pool that may reach zero, including the standard
Ubuntu 22.04 pool. Helm replaces list values, so later values files must carry
the complete queue list you want to retain.

Match declarations to the worker configuration:

- Copy the complete `spec.config.generated.platformProperties`, preserving
  case and exact values, sorted by property name and then value. Match the
  platform requested by Bazel after any scheduler action routing. The runner
  image alone does not define the advertised platform.
- Use `sizeClasses: [0]` for a single-class pool whose
  `spec.config.generated.sizeClass` is omitted or zero. Multiple classes share
  the same platform and declare their increasing positive classes, such as
  `[1, 2]`. The largest class must support the workloads retried from smaller
  classes. See the [ISCC runbook](../../docs/iscc-size-classes.md).
- Starter generated workers register with an empty instance-name prefix.
  Omit `instanceNamePrefix` from their queue declarations and leave
  `spec.autoscaling.prometheus.instanceNamePrefix` empty. Changing the metric
  query prefix alone does not change worker registration.
- A private pool serves a single tenant. Set
  `spec.config.generated.instanceNamePrefix` to the tenant's instance name,
  the Hermetiq project ID its Bazel clients send as `--remote_instance_name`.
  Its workers then register under that prefix and receive only that tenant's
  actions. Declare the queue with the same `instanceNamePrefix`, platform, and
  `sizeClasses`. The generated KEDA query picks up the worker's prefix, so
  leave `spec.autoscaling.prometheus.instanceNamePrefix` empty.

A private pool and its matching queue declaration:

```yaml
# RbeWorker
spec:
  config:
    generated:
      instanceNamePrefix: 3f6c1d2e-8b4a-4c7e-9a1d-5e2f7b9c0a14
      platformProperties:
        - { name: pool, value: private-linux-x86-64 }
```

```yaml
# Buildbarn Helm values
scheduler:
  predeclaredPlatformQueues:
    - instanceNamePrefix: 3f6c1d2e-8b4a-4c7e-9a1d-5e2f7b9c0a14
      platform:
        - { name: pool, value: private-linux-x86-64 }
      sizeClasses: [0]
```

Pool names, platform values, and images appear in shared scheduler and worker
metrics. Keep them neutral and leave customer names out of them; the instance
name alone ties a private pool to its tenant.

For each pool that should scale down to zero, set these fields on its
`RbeWorker`, retaining its Prometheus endpoint, metric threshold, and other
pool-specific settings:

```yaml
spec:
  replicas: 0
  autoscaling:
    enabled: true
    minReplicas: 0
    maxReplicas: 20
```

The worker operator creates the Deployment and KEDA ScaledObject. Its queue
query must reach the scheduler metrics for the worker's namespace, platform,
instance prefix, and size class. Keep scheduler scraping and the Buildbarn
recording rules running while worker pools are at zero. The chart's
`keda.frontend` settings control frontend replicas independently.

Verify the rendered scheduler declarations against the rendered RbeWorkers
before upgrading. On an idle test pool, submit a small action that misses the
action cache, then watch queued work, desired replicas, and ready workers.
Allow for metric collection and KEDA polling, node provisioning, image pulls,
and worker registration. A predeclared queue supplies the scheduling identity;
the nodes must still satisfy the [pod scheduling requirements](#pod-scheduling).

## Pod scheduling

Review scheduling before applying any pool. KEDA can request worker replicas,
but those Pods still need nodes that satisfy their resource requests, selectors,
taints, runtime, and scratch-storage needs.

- The examples select only standard Kubernetes `amd64` Linux node labels. They
  do not select a cloud provider, node pool, or spot nodes. Use an environment
  overlay to add `spec.pod.nodeSelector` and `spec.pod.tolerations` for dedicated
  pools or tainted nodes. Make sure a matching node or node autoscaler can
  supply the requested CPU and memory; the example resource sizes are large.
- The CAS scratch volumes use `emptyDir`. Their data is lost when a Pod is
  removed, and they consume node ephemeral storage alongside image layers and
  other scratch files. Check available disk capacity and set appropriate
  ephemeral-storage requests and limits for your cluster. If you use a local
  disk through `hostPath` instead, patch `spec.storage.casVolume` and ensure
  concurrently scheduled workers cannot share the same CAS cache path. The
  path must be under one of the operator's `specPolicy.allowedHostPathPrefixes`;
  the default allows GKE's `/mnt/stateful_partition/kube-ephemeral-ssd`. See
  [RbeWorker Spec Policy](../../charts/bb-worker-operator/README.md#rbeworker-spec-policy).
- Docker-in-Docker workers need nodes and Pod policies that permit their
  privileged Docker container. Sysbox workers need Sysbox installed on the
  selected nodes and the `sysbox-runc` RuntimeClass. Configure RuntimeClass
  scheduling or an overlay so Sysbox Pods cannot land on nodes without Sysbox.

Before running builds, check that the worker Pods reached their intended nodes.
For a Pending Pod, `kubectl describe` shows scheduling failures such as missing
labels, untolerated taints, or insufficient CPU, memory, and ephemeral storage:

```bash
kubectl -n hermetiq get pods -l app=worker -o wide
kubectl -n hermetiq describe pod <pending-worker-pod>
```

FUSE-backed pools get `spec.storage.fuse.cleanupOnTermination: true` by default.
The worker operator renders a Kubernetes-native sidecar that terminates after
the worker and runner and lazily unmounts `/worker/build`, preventing dead FUSE
mounts from blocking kubelet Pod cleanup. Pools without `spec.storage.fuse` get
no cleanup sidecar; a FUSE pool can explicitly opt out with
`cleanupOnTermination: false`. This requires bb-worker-operator v0.3.3 or newer
and Kubernetes 1.29 or newer.

## Worker and runner memory

Each worker Pod divides its memory between the runner container, where actions
execute, and the worker container, which runs bb_worker. bb_worker memory-maps
the operator-generated 16 GiB local CAS and, in pools with a virtual build
directory, the file pool. The kernel charges the page cache for those reads to
the worker container, so its limit must hold that cache as well as bb_worker's
heap. When the limit is too small, cached data is read from disk again and
again: the node reports a high major page-fault rate (for example, the
node-exporter `NodeMemoryMajorPagesFaults` alert), and the worker container
reads several times more from disk than it writes.

The examples give the worker container 9Gi, or 4Gi for Ubuntu 24.04 and the
Testcontainers pools, alongside each runner's separate memory budget. When you
resize a pool:

- Lower the runner only after comparing its peak working set
  (`container_memory_working_set_bytes{container="runner"}`) with its limit.
  Actions are killed when the runner reaches its limit.
- An overlay that changes only the runner's memory still adds the worker's
  request to every Pod. Check that both fit on the target nodes.
- If the worker container keeps reading more from disk than it writes
  (`container_fs_reads_bytes_total` and `container_fs_writes_bytes_total` with
  `container="worker"`), its cache does not fit in its limit.

## FUSE kernel tuning

All eight FUSE-backed examples configure
`spec.config.generated.virtualBuildDirectory.fuse` explicitly. One FUSE mount
serves every concurrent action in a Pod; the kernel's default of 12 background
requests can bottleneck asynchronous readahead and writeback on these pools.
The examples start `maximumBackgroundTasks` at
`128 × max(runner CPU limit in cores, concurrency)`:

| Pools | `maximumBackgroundTasks` |
|---|---:|
| Ubuntu 22.04, Codex, size class large, Drake | 1664 |
| Ubuntu 24.04, Envoy | 2048 |
| Size class small | 3072 |
| Testcontainers (DinD) | 1024 |

Recompute this value whenever an overlay changes
`spec.runner.resources.limits.cpu` or `spec.config.generated.concurrency`;
`13000m` means 13 CPU cores. These are starting points for load testing, not
values the operator recalculates automatically. The Sysbox example uses a
native build directory and has no FUSE tunables.

Each FUSE example also sets `linuxBackingDevInfoTunables` to
`{max_ratio: "10", strict_limit: "0"}`. These per-mount settings increase its
share of the kernel writeback cache and relax strict per-device dirty limits
for random-access writes. They do not reserve 10% of node RAM or increase the
worker container's memory limit.

Before applying the examples, check the **node kernel**, regardless of the
runner's Ubuntu version:

```bash
kubectl get nodes -o custom-columns=NODE:.metadata.name,KERNEL:.status.nodeInfo.kernelVersion
kubectl explain rbeworker.spec.config.generated.virtualBuildDirectory.fuse
```

`strict_limit` requires Linux 6.2 or newer. The worker must also be able to
write the mount's `/sys/class/bdi/<major>:<minor>/` files; these examples already
run the worker privileged. If a configured file is absent or unwritable,
`bb_worker` fails at startup. For older kernels or read-only sysfs, remove the
`linuxBackingDevInfoTunables` map from each affected pool while keeping
`maximumBackgroundTasks`. For example, add this to an overlay's `patches` list
for Ubuntu 22.04, repeating it for any other affected FUSE pools:

```yaml
patches:
  - target:
      group: bb.hermetiq.com
      version: v1
      kind: RbeWorker
      name: worker-ubuntu22-04
    patch: |-
      - op: remove
        path: /spec/config/generated/virtualBuildDirectory/fuse/linuxBackingDevInfoTunables
```

Changing these fields rolls the pool's Pods. When updating an existing
installation, start with one pool and confirm that its workers stay healthy.
See the [operator's kernel tunables guide](../../charts/bb-worker-operator/README.md#kernel-tunables)
for the upstream guidance and sysfs access details. An overlay using JSON Patch
`add` or `replace` on the whole `fuse` object replaces these defaults; patch
individual fields when you want to retain the other settings.

## Environment overlays

For another environment, reference this directory from a Kustomize overlay.
Set its namespace to the Buildbarn release namespace and patch the
environment-specific values without copying the worker manifests:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: example

resources:
  - ../../path/to/custom-values/rbeworkers

patches:
  - target:
      group: bb.hermetiq.com
      version: v1
      kind: RbeWorker
    patch: |-
      - op: replace
        path: /spec/autoscaling/prometheus/serverAddress
        value: http://vmselect-vm.observability.svc.cluster.local:8481/select/0/prometheus
      - op: replace
        path: /spec/config/generated/completedActionLoggerAddress
        value: bep-nats-pub.example.svc.cluster.local:50091
  - target:
      group: bb.hermetiq.com
      version: v1
      kind: RbeWorker
      name: worker-ubuntu22-04
    patch: |-
      - op: replace
        path: /spec/autoscaling/minReplicas
        value: 2
      - op: add
        path: /spec/pod/nodeSelector/node-type
        value: spot-std-large
      - op: add
        path: /spec/pod/tolerations
        value:
          - key: hermetiq/allows-spot
            operator: Exists
            effect: NoSchedule
```

The JSON Patch `replace` operations intentionally fail if a future manifest no
longer contains one of these fields, preventing an overlay from silently
leaving a worker pointed at the starter environment. The node selector and
toleration above are examples for one pool; replace them with your own node
labels and taints.

The size-class, Testcontainers, and Drake manifests are intentionally excluded
from the standard bundle. Apply them only after satisfying the scheduler,
node-pool, and container-runtime prerequisites in the
[Buildbarn chart README](../../charts/buildbarn/README.md#node-pool-prerequisites)
and the [ISCC size-class runbook](../../docs/iscc-size-classes.md). Add any
combination to the environment overlay with `components`:

```yaml
resources:
  - ../../path/to/custom-values/rbeworkers

components:
  # Adds both worker-sizeclass-small and worker-sizeclass-large.
  - ../../path/to/custom-values/rbeworkers/optional/sizeclass
  # Adds the Docker-in-Docker Testcontainers worker.
  - ../../path/to/custom-values/rbeworkers/optional/testcontainers
  # Adds the Sysbox Testcontainers worker.
  - ../../path/to/custom-values/rbeworkers/optional/testcontainers-sysbox
  # Adds the Drake worker. Requires publishing examples/drake-runner-image first.
  - ../../path/to/custom-values/rbeworkers/optional/drake
```

The overlay's namespace and `RbeWorker` patch apply to component resources too,
so the optional workers receive the same environment-specific addresses as the
standard bundle. Set the overlay namespace to the Buildbarn release namespace:
generated queue-depth queries filter by each worker's namespace, and the
operator reads `buildbarn-worker-config` there.

## Pod security

Worker pods can't meet Pod Security Standards `restricted`, because the FUSE
build directory needs privileged containers:
- The `worker` container runs privileged as root.
- The operator's `fuse-cleanup` sidecar runs privileged as root.
- Docker-in-Docker pools also run `dind` privileged.

Run the pools in the same namespace as Buildbarn. That namespace must permit
privileged worker Pods, for example with
`pod-security.kubernetes.io/enforce: privileged`; it cannot enforce
`restricted`. Give the pools dedicated nodes. The Buildbarn chart's storage
and scheduler NetworkPolicies already admit same-namespace `app=worker` Pods,
so these examples need no additional peer entries.

Everything else is hardened:
- **Operator-owned containers:** the runner installer runs non-root and
  read-only. `volume-init` runs as root with only `DAC_OVERRIDE` and `FOWNER`.
- **ServiceAccount token:** the operator mounts none unless
  `spec.pod.automountServiceAccountToken` is `true`. Build actions therefore
  can't read Kubernetes credentials.
- **Runners in these examples:** they run as a non-root user with no privilege
  escalation and no capabilities.

For regulated environments, the runner can also take the settings below. Test
them against your builds first, since they change the actions' primary group
and block some syscalls:

```yaml
spec:
  runner:
    securityContext:
      runAsGroup: 65534
      seccompProfile:
        type: RuntimeDefault
```
