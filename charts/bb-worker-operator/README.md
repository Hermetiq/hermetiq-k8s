# BB Worker Operator Helm Chart

Installs the Buildbarn worker operator and the `rbeworkers.bb.hermetiq.com` CRD.
Use the repository's
[installation guide](https://github.com/Hermetiq/hermetiq-k8s#readme) for the
supported full-stack deployment order.

## Contents

- [Install](#install)
- [Verify](#verify)
- [CRD Lifecycle](#crd-lifecycle)
  - [Replacing the CRD from scratch](#replacing-the-crd-from-scratch)
- [Upgrading to 1.0.0](#upgrading-to-100)
- [Upgrading to 0.3.12](#upgrading-to-0312)
- [Upgrading to 0.3.11](#upgrading-to-0311)
- [RbeWorker Pools](#rbeworker-pools)
  - [Configuration modes](#configuration-modes)
  - [Completed-action logger address](#completed-action-logger-address)
  - [FUSE build directories](#fuse-build-directories)
  - [Draining actions on termination](#draining-actions-on-termination)
  - [Docker-capable workers](#docker-capable-workers)
- [KEDA Autoscaling](#keda-autoscaling)
  - [Private pools](#private-pools)
  - [Scaling to zero](#scaling-to-zero)
  - [Tuning generated autoscaling](#tuning-generated-autoscaling)
  - [Diagnose a pool that does not scale](#diagnose-a-pool-that-does-not-scale)
- [Security Context](#security-context)
- [RbeWorker Spec Policy](#rbeworker-spec-policy)
  - [Keeping the previous behavior](#keeping-the-previous-behavior)
- [RBAC Scope](#rbac-scope)
- [Observability](#observability)
- [Local chart development](#local-chart-development)
- [License](#license)

## Install

The Buildbarn release and its `RbeWorker` pools must share a namespace. FUSE
workers need privileged containers, so if Pod Security Admission enforces a
restrictive policy, allow privileged Pods in that namespace before applying
the worker pools:

```bash
kubectl label namespace hermetiq pod-security.kubernetes.io/enforce=privileged --overwrite
```

Use dedicated worker nodes. A Hermetiq release installed in a separate
namespace can retain `restricted` admission there. Install the
namespace-scoped operator alongside Buildbarn so it reconciles their shared
worker pools.

Start with the
[operator starter values](https://github.com/Hermetiq/hermetiq-k8s/blob/main/custom-values/bb-worker-operator-values.yaml),
copied as described in the
[repository setup guide](https://github.com/Hermetiq/hermetiq-k8s#prepare-custom-values).
Run the commands below from inside your copied values directory.

Inspect this release's packaged documentation and defaults before editing the
operator values:

```bash
helm show readme oci://ghcr.io/hermetiq/bb-worker-operator --version 1.0.0
helm show values oci://ghcr.io/hermetiq/bb-worker-operator --version 1.0.0
```

For a namespace-scoped install, set `rbac.mode=namespace` and
`metrics.secure=false` in the values file. Have a cluster administrator apply
the CRD from the matching release tag:

```bash
kubectl apply --server-side -f \
  https://raw.githubusercontent.com/Hermetiq/hermetiq-k8s/bb-worker-operator-v1.0.0/charts/bb-worker-operator/crds/bb.hermetiq.com_rbeworkers.yaml
kubectl wait --for=condition=Established crd/rbeworkers.bb.hermetiq.com --timeout=60s
```

Then install the controller in the namespace:

```bash
helm upgrade --install --namespace hermetiq bb-worker-operator \
  oci://ghcr.io/hermetiq/bb-worker-operator \
  --version 1.0.0 \
  --skip-crds \
  --values bb-worker-operator-values.yaml
```

See [RBAC Scope](#rbac-scope) for the remaining namespace-mode requirements.
If the Helm installer can create cluster-scoped resources, the separate CRD
step is optional: omit `--skip-crds` and Helm installs the CRD on the first
install. For later upgrades, apply the updated CRD separately before upgrading
the chart.

Keep the CRD and controller image on the same release. Leave `image.tag` empty
so the image follows the chart's `appVersion`: the CRD is what accepts a field
and the controller is what acts on it, so a controller older than the CRD
silently ignores fields it does not know.

## Verify

```bash
kubectl wait --for=condition=Established crd/rbeworkers.bb.hermetiq.com --timeout=60s
kubectl -n hermetiq rollout status deployment/bb-worker-operator --timeout=120s
kubectl -n hermetiq get rbeworkers
```

`kubectl get rbeworkers` is empty until you apply worker pools, which depend on
the `buildbarn-worker-config` ConfigMap rendered by the Buildbarn chart. Start
from the
[sample worker pools](https://github.com/Hermetiq/hermetiq-k8s/blob/main/custom-values/rbeworkers/README.md)
under `rbeworkers/` in your copied values directory. Once pools exist, each
`RbeWorker` reports the Deployment, ConfigMap, and KEDA `ScaledObject` it
manages in its status.

When `podDisruptionBudget.enabled=true`, the chart sets
`unhealthyPodEvictionPolicy: AlwaysAllow`. Node drains can evict an unready
operator Pod even when its healthy Pod budget is exhausted.

Once the CRD is established and the operator Deployment is ready, continue with
[installing Buildbarn and its worker pools](../../README.md#install-buildbarn-and-worker-pools).

## CRD Lifecycle

`RbeWorker` is a cluster-wide Kubernetes API, even when the operator watches
only one namespace. Its CRD is packaged in the chart's `crds/` directory:

```text
charts/bb-worker-operator/crds/bb.hermetiq.com_rbeworkers.yaml
```

The recommended way to install or upgrade the CRD is to apply the versioned
file and wait for Kubernetes to establish it. This example uses release 1.0.0;
use the target chart's release tag when upgrading:

```bash
kubectl apply --server-side -f \
  https://raw.githubusercontent.com/Hermetiq/hermetiq-k8s/bb-worker-operator-v1.0.0/charts/bb-worker-operator/crds/bb.hermetiq.com_rbeworkers.yaml
kubectl wait --for=condition=Established crd/rbeworkers.bb.hermetiq.com --timeout=60s
```

On a **first install**, Helm installs the CRD before the controller if you omit
`--skip-crds` and the installer has cluster-wide permissions. The
namespace-scoped path in [Install](#install) instead has a cluster administrator
apply the CRD, then installs the controller with `--skip-crds`.

On an **upgrade**, run the CRD command above before upgrading the chart or
applying `RbeWorker` manifests that use new fields. Helm does not upgrade CRDs in
`crds/` during `helm upgrade`, even when the chart contains a newer schema.
If Helm created the CRD on the first install, `kubectl` can stop with a
conflict against the `helm` field manager on `.spec.versions`. The new schema
is meant to replace the old one, so run the same command again with
`--force-conflicts` added.
Keep the chart and CRD at the same version, and leave `image.tag` empty so the
controller follows the chart's `appVersion`. A newer CRD may accept fields
that an older controller cannot act on.

On **uninstall**, Helm leaves the CRD in place. Deleting that CRD also deletes
all `RbeWorker` objects in the cluster, so remove it only when you intend to
retire the API and those worker pools.

If upgrading from a release before 0.3.3, the target release's CRD includes
updated Pod and volume schemas. If upgrading from a release before 0.3.4,
remove `spec.autoscaling.prometheus.projectID` from `RbeWorker` manifests and
Kustomize patches before reapplying them; the CRD no longer accepts that field.
Generated queries now use the `RbeWorker` namespace, so each worker must share
a namespace with the Buildbarn scheduler it scales on.

For a rendered install bundle, pass `--include-crds` to `helm template` as shown
in [Local chart development](#local-chart-development); Helm omits CRDs from
its default template output.

### Replacing the CRD from scratch

Updating the CRD in place, as above, is the normal path. To replace it from
scratch instead, delete it and apply the new one. **Deleting the CRD deletes
every `RbeWorker` in the cluster**, and Kubernetes then garbage-collects each
pool's Deployment, generated ConfigMap, and `ScaledObject`, so keep your
`RbeWorker` manifests to re-apply afterward.

```bash
# 1. Stop the controller so it does not react while the API disappears.
kubectl -n hermetiq scale deployment/bb-worker-operator --replicas=0

# 2. Delete the old CRD. This deletes existing RbeWorker objects too.
kubectl delete crd rbeworkers.bb.hermetiq.com --wait=true --ignore-not-found

# 3. Apply the CRD from the release you are installing, and wait for it.
kubectl apply --server-side -f \
  https://raw.githubusercontent.com/Hermetiq/hermetiq-k8s/bb-worker-operator-v1.0.0/charts/bb-worker-operator/crds/bb.hermetiq.com_rbeworkers.yaml
kubectl wait --for=condition=Established crd/rbeworkers.bb.hermetiq.com --timeout=60s

# 4. Upgrade or restart the controller on the same release.
helm upgrade --install --namespace hermetiq bb-worker-operator \
  oci://ghcr.io/hermetiq/bb-worker-operator \
  --version 1.0.0 \
  --skip-crds \
  --values bb-worker-operator-values.yaml
```

Then re-apply your `RbeWorker` manifests.

## Upgrading to 1.0.0

Chart 1.0.0 follows 0.3.12; the chart version now moves together with the
Hermetiq and Buildbarn charts, and no chart was published in between. It
deploys operator v0.3.14, which supports the Buildbarn chart's
content-defined chunking (CDC) storage. The operator reads the shape of
`blobstore.contentAddressableStorage` in the Buildbarn chart's
`common.libsonnet`: with `chunkStorage` it generates the CDC worker blobstore
(`chunkStorage`, `chunkMappingStorage`, the CDC caches and `portalUrl`), and
otherwise the same pre-CDC config as before. Install this operator **before**
installing or upgrading the Buildbarn chart to 1.0.0, whose checks require it
on `helm install` as well as `helm upgrade`.

This upgrade rolls worker pools, so schedule it: run it inside the Buildbarn
[cut-over window](../../docs/buildbarn-storage-model.md#storage-format-cutover-and-rollback),
or in a separate window that you announce.

- Apply the 1.0.0 CRD first. `spec.images.worker` and
  `spec.images.runnerInstaller` become optional: when unset, the operator uses
  the `workerImage` and `runnerInstallerImage` keys of the referenced config
  ConfigMap, which the Buildbarn chart publishes, so worker images follow the
  Buildbarn release.
- Keep existing image pins while upgrading the operator. Before removing them
  on a pre-CDC Buildbarn installation, populate those two ConfigMap keys with
  the exact **currently running pre-CDC images**, including their digests.
  The older Buildbarn chart does not publish the keys itself. Removing pins
  without this staging step makes the operator report `SpecInvalid` until the
  Buildbarn upgrade supplies the keys. After staging, remove the pins and
  verify the pools reconcile; the CDC Buildbarn upgrade then changes the
  shared configuration and inherited images together. Do not update worker
  images to CDC while their shared configuration is still pre-CDC.
- Every generated-config worker pool restarts once, because the embedded
  `worker-common.libsonnet` changed. Pre-CDC worker configs evaluate unchanged.
  The restart is a rolling update of each pool's Deployment as soon as the new
  operator reconciles it, on every pool at once; actions that outlast the
  pod's termination grace period are killed (see
  [Draining actions on termination](#draining-actions-on-termination)). A pool
  with `spec.config.rolloutOnChange: false` is not rolled and picks the new
  file up when its Pods next restart.
- To stop a pool for the cut-over, pause it on the `RbeWorker`. While
  `spec.autoscaling.enabled` is true, `spec.replicas` is ignored: the operator
  leaves the Deployment's replica count to KEDA. A pause annotation set
  directly on the `ScaledObject` does not last either, because the operator
  replaces that object's annotations with
  `spec.autoscaling.scaledObjectAnnotations` on every reconcile. Set KEDA's
  pause annotation there, and remove it again to resume:

  ```yaml
  spec:
    autoscaling:
      scaledObjectAnnotations:
        autoscaling.keda.sh/paused-replicas: "0"
  ```

  A pool without autoscaling stops with `spec.replicas: 0`. With
  `spec.manageReplicas: false` the operator sets neither, and you scale the
  Deployment or its external scaler yourself.
- After a Buildbarn rollback to a pre-CDC chart, the `workerImage` and
  `runnerInstallerImage` keys are gone again: the older chart does not render
  them. Pools without image pins then report `SpecInvalid`, and the operator
  leaves their Deployments on the CDC images. As part of the rollback, set
  `spec.images.worker` and `spec.images.runnerInstaller` back to the pre-CDC
  images on each `RbeWorker`, or populate the two keys again after the
  rollback has replaced the ConfigMap.
- A pool that projects its own copy of `worker-common.libsonnet` through
  `commonItems` is read by the Buildbarn chart's configuration text check like
  any other worker configuration. A copy based on this operator's built-in
  file passes it: the check accepts a file that tests for the CDC shape itself
  (it contains `std.objectHas` and the word `chunkStorage`) and does not
  refuse it for the pre-CDC branch it carries. A copy without that test must
  contain no pre-CDC fields before the Buildbarn upgrade.
- The operator Deployment carries `hermetiq.com/cdc-compatible: "true"` when
  its effective image digest matches the chart's known CDC-capable default.
  Registry mirrors and tag changes that retain that digest preserve the
  declaration. Other digests and tag-only images do not automatically receive
  it: set `buildbarnCdcCompatible: true` only after verifying that your custom
  operator handles both configuration schemas. The Buildbarn chart requires
  this declaration on install and on upgrade; chart and app-version labels
  alone do not prove that an overridden image supports CDC.

When upgrading from 0.3.11 or earlier, also follow
[Upgrading to 0.3.12](#upgrading-to-0312).

## Upgrading to 0.3.12

Chart 0.3.12 deploys the same operator v0.3.13 as 0.3.11 and has the same
CRD. The default image is now pinned to its SHA-256 manifest digest, so the
operator Deployment rolls once on upgrade. Worker pools are not restarted.

`image.digest` takes precedence over `image.tag`. If you override `image.tag`,
also set `image.digest` to that image's digest, or clear it with
`--set-string image.digest=`. Otherwise the operator keeps running the pinned
v0.3.13 image. See [image integrity](../../docs/image-integrity.md).

When upgrading from 0.3.10 or earlier, also follow
[Upgrading to 0.3.11](#upgrading-to-0311).

## Upgrading to 0.3.11

Chart 0.3.11 deploys operator v0.3.13, which stops reconciling an `RbeWorker`
in two new cases. It sets `Ready=False` and leaves that pool's existing
Deployment and `ScaledObject` as they are, so running workers keep running and
autoscaling, but changes to the `RbeWorker` no longer reach them:

- **`SpecInvalid`**: the spec asks for something the
  [RbeWorker Spec Policy](#rbeworker-spec-policy) does not allow, such as a
  `hostPath` CAS volume outside the allowed prefixes.
- **`NameConflict`**: a Deployment, generated ConfigMap or `ScaledObject` with
  the pool's name exists but is not controlled by this `RbeWorker`, or
  `spec.config.generated.commonConfigMapName` is `<name>-config`. Objects the
  operator created already carry the right owner reference. A conflict usually
  means the `RbeWorker` was deleted with `--cascade=orphan` and recreated.

To catch both before they happen, `helm install` and `helm upgrade` list the
`RbeWorker` objects the operator watches and fail with each problem and the
fix, for example:

```text
Error: execution error at (bb-worker-operator/templates/validate.yaml:31:4): bb-worker-operator v0.3.13 and newer would stop reconciling these existing RbeWorkers:
  - buildbarn/worker-cas: spec.storage.casVolume.hostPath.path "/mnt/disks/ssd0/cas" needs a covering entry in specPolicy.allowedHostPathPrefixes
```

Widen `specPolicy` or fix the `RbeWorker` objects, then rerun the upgrade. To
see the result without changing anything, render against the cluster first:

```bash
helm template bb-worker-operator oci://ghcr.io/hermetiq/bb-worker-operator \
  --version 1.0.0 --namespace hermetiq --dry-run=server \
  --values bb-worker-operator-values.yaml > /dev/null
```

The check reads the cluster through Helm's `lookup`, so it needs permission to
list `RbeWorker` objects in the watched scope and to get Deployments,
ConfigMaps and `ScaledObject`s in their namespaces. It does nothing under
`helm template` without `--dry-run=server`, or under GitOps tools that render
charts client-side, such as Argo CD. In those setups run the command above from
a workstation before syncing. Set `specPolicy.checkExistingRbeWorkers=false` to
skip it.

Pools that use Docker-in-Docker restart once during the upgrade, because dockerd
now runs as a Kubernetes-native sidecar (Kubernetes 1.29 or newer). Other pools
keep their pod template. Apply the target release's CRD first as described in
[CRD Lifecycle](#crd-lifecycle), which adds the
[FUSE kernel tunables](#kernel-tunables).

## RbeWorker Pools

Each `RbeWorker` describes one Buildbarn worker pool. The operator creates an
owned `Deployment`, an owned generated ConfigMap when you use generated config,
and, when autoscaling is enabled, a KEDA `ScaledObject`. The Buildbarn chart's
[sample worker pools](https://github.com/Hermetiq/hermetiq-k8s/blob/main/custom-values/rbeworkers/README.md)
are complete `RbeWorker` manifests to copy from, with notes on pod scheduling,
memory sizing, and environment overlays.

### Configuration modes

A pool takes its Buildbarn config in one of two modes:

- `spec.config.generated`: you provide common pool settings such as
  `platformProperties`, `concurrency`, action environment, the virtual build
  directory, and runner user settings, and the operator renders the standard
  worker and runner Jsonnet files.
- `spec.config.files`: for expert use, you provide a ConfigMap that holds the
  complete Jsonnet files and choose `workerConfigPath` and `runnerConfigPath`.

Generated config imports `common.libsonnet` from a same-namespace ConfigMap named
by `spec.config.generated.commonConfigMapName`. That file stays the place for
cluster-wide Buildbarn settings such as storage, the browser URL, message size,
tracing, and diagnostics. The Buildbarn chart renders it as
`buildbarn-worker-config`.

### Completed-action logger address

For generated config, set `spec.config.generated.completedActionLoggerAddress`
to the publisher's full address, for example
`bep-nats-pub.hermetiq.svc.cluster.local:50091`. The operator passes it to the
worker container as `BBCAL_ADDRESS`, which the generated Jsonnet reads with
`std.extVar('BBCAL_ADDRESS')`, so the generated Jsonnet carries no
environment-specific endpoint.

An explicit `spec.worker.env` entry named `BBCAL_ADDRESS` takes precedence over
that field and can use `value` or `valueFrom`:

```yaml
spec:
  worker:
    env:
      - name: BBCAL_ADDRESS
        valueFrom:
          configMapKeyRef:
            name: worker-endpoints
            key: completed-action-logger
```

When neither is set, the operator supplies an empty `BBCAL_ADDRESS`, which
disables completed-action logging. Use `spec.worker.env` for the override: the
generated default takes precedence over entries supplied by `envFrom`. Changing
the address in the `RbeWorker` updates the Deployment's pod environment and
triggers a rollout even when `spec.config.rolloutOnChange` is false. If the
address comes from a referenced ConfigMap or Secret, restart the worker Pods
after changing that external value so they receive the new environment.

When upgrading from an operator release that embedded the address in the
generated Jsonnet, first add `BBCAL_ADDRESS` to `spec.worker.env` with the
current address (or an empty value to keep logging disabled) and let that
rollout finish before upgrading the operator. Generated ConfigMaps are updated
in place, so this staging lets an old Pod still restart successfully after its
Jsonnet starts reading the environment. Afterward you can remove the explicit
entry and use `completedActionLoggerAddress` again.

For `spec.config.files`, the logger configuration and environment stay under
your control. A custom `worker-common.libsonnet` used with generated config
still receives `config.completedActionLoggerAddress` as a string.

### FUSE build directories

A pool that sets `spec.config.generated.virtualBuildDirectory` and
`spec.storage.fuse` runs its build directory on a FUSE mount, which needs the
privileged containers described under [Security Context](#security-context).

#### Cleanup on termination

FUSE-backed workers enable `spec.storage.fuse.cleanupOnTermination` by default.
The operator adds a Kubernetes-native sidecar that stays alive until the worker
and runner containers stop, then lazily unmounts `<workerMountPath>/build`
through a bidirectional mount. This avoids leaving a dead FUSE mount that
prevents kubelet from deleting the worker `emptyDir` and Pod. No sidecar is
added when `spec.storage.fuse` is absent. Set the field to `false` to opt out:

```yaml
spec:
  storage:
    fuse:
      cleanupOnTermination: false
```

The sidecar uses `spec.images.volumeInit` (or the operator's BusyBox default),
runs privileged so the bidirectional unmount reaches the node, and requires
Kubernetes 1.29 or newer. Keep enough pod termination grace time for the main
containers to stop and the sidecar's termination handler to run. Cleanup runs on
the sidecar's termination signal, never in `preStop`, because that hook can
execute before the main containers have stopped. The sidecar logs each cleanup
attempt and any failure.

#### Kernel tunables

A pool with a virtual build directory serves every concurrent action in a Pod
from one FUSE mount, and the Linux defaults for that mount are sized for light
use. Two optional fields under `virtualBuildDirectory.fuse` raise those limits.
The operator leaves both unset by default, so pools that do not set them keep
the worker config they had before. The [example FUSE pools](../../custom-values/rbeworkers/README.md#fuse-kernel-tuning)
set both explicitly and document the node prerequisites and how to opt out.

```yaml
spec:
  config:
    generated:
      virtualBuildDirectory:
        # filePoolPath, filePoolSizeBytes, ... as usual
        fuse:
          maximumBackgroundTasks: 1664
          linuxBackingDevInfoTunables:
            max_ratio: "10"
            strict_limit: "0"
```

- `maximumBackgroundTasks` sets the FUSE `max_background` limit: how many
  asynchronous requests, mostly readahead and writeback, the kernel keeps in
  flight for the mount. The kernel default is 12, and once three quarters of the
  limit is queued the kernel throttles further async requests, so a mount shared
  by many concurrent actions stalls reads. The
  [Meroton FUSE worker guidance](https://meroton.com/blog/fuse-guidance/)
  suggests 128 per runner vCPU, so a 13 vCPU runner would use 1664. Buildbarn's
  own documentation of the option suggests roughly 128 per worker thread, which
  here is `concurrency`. Start from whichever is larger, and tune upward if reads
  still stall under sustained concurrency.
- `linuxBackingDevInfoTunables` writes the listed files under the mount's
  `/sys/class/bdi/<major>:<minor>/` directory. `max_ratio: "10"` with
  `strict_limit: "0"` enlarges the mount's share of the kernel write-back cache
  and speeds up random-access writes on large runners.

Before enabling them:

- `strict_limit` exists only on Linux 6.2 and newer. Check the kernel version of
  the nodes that run the pool, for example with
  `kubectl get nodes -o custom-columns=NODE:.metadata.name,KERNEL:.status.nodeInfo.kernelVersion`.
- The worker container must be able to write `/sys`. A privileged worker
  container normally can. Otherwise you can mount the host's `/sys` with
  `spec.pod.extraVolumes` and `spec.worker.extraVolumeMounts`, though Kubernetes
  may still make it read-only depending on the other containers in the Pod. A
  `hostPath` for `/sys` must be allowed by `specPolicy.allowedHostPathPrefixes`
  (see [RbeWorker Spec Policy](#rbeworker-spec-policy)).
- `bb_worker` exits at startup if it cannot write one of the listed files, and
  Kubernetes then restarts it in a crash loop. The operator cannot check the
  node's kernel or `/sys` access. It rejects only names that are not plain sysfs
  file names (lowercase letters, digits, and underscores) and values that are not
  unsigned integers, with reason `SpecInvalid`. Roll the change out to one pool
  first and confirm its workers start and stay healthy.
- The fields exist only in operator and CRD releases that include them. Check the
  installed CRD with
  `kubectl explain rbeworker.spec.config.generated.virtualBuildDirectory.fuse`:
  if the two fields are not listed, upgrade the CRD and controller together as
  described in [CRD Lifecycle](#crd-lifecycle) before applying them.

Setting or changing either field changes the generated worker config and the
Deployment's `bb.hermetiq.com/config-hash` annotation, so that pool's Pods roll
to pick it up.

### Draining actions on termination

Kubernetes sends SIGTERM to `bb_worker` and `bb_runner` at the same time. The
generated runner config sets `stopGracefully: true`, so `bb_runner` lets the
in-flight action finish instead of aborting it. A custom
`worker-common.libsonnet` supplied through `commonItems` should set it in its
`runnerConfig` too. Kubernetes still kills both containers when
`spec.pod.terminationGracePeriodSeconds` (60 seconds by default) runs out, so
raise it for pools whose actions run longer.

### Docker-capable workers

Docker-capable Bazel actions, such as Testcontainers tests, use
`spec.docker.mode`:

- `dind` adds a privileged Docker-in-Docker sidecar, a shared
  `/var/run/docker.sock`, registry mirrors, and image preloading. It is a
  Kubernetes-native sidecar, so on termination dockerd stops only after the
  runner has drained, and the worker starts once dockerd is ready and images are
  preloaded.
- `sysbox` assumes the runner image starts Docker under a Sysbox runtime and
  already contains `/bb/bb_runner`; the runner installer is disabled by default.
  The nodes need Sysbox installed and the `sysbox-runc` RuntimeClass.

The `testcontainers` and `testcontainers-sysbox` components in the
[sample worker pools](https://github.com/Hermetiq/hermetiq-k8s/blob/main/custom-values/rbeworkers/README.md)
are ready-made pools for each mode. Advertise a pool property such as
`pool=testcontainers` or `pool=testcontainers-sysbox`, then route Bazel targets
with matching `exec_properties`.

Bazel test processes should set the Docker environment directly on the test rule,
because Bazel's test wrapper may not preserve worker-injected action environment:

```python
go_test(
    name = "redis_test",
    env = {
        "DOCKER_HOST": "unix:///var/run/docker.sock",
        "TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE": "/var/run/docker.sock",
        "TESTCONTAINERS_HOST_OVERRIDE": "localhost",
    },
    exec_properties = {"pool": "testcontainers"},
)
```

## KEDA Autoscaling

The bundled CRD supports the operator's generated Prometheus scaler plus
additional KEDA features such as cron windows, arbitrary extra triggers,
ScaledObject annotations, fallback behavior, HPA behavior overrides, and scaling
modifiers.

KEDA cron triggers enforce a replica floor during a time window. For example,
this keeps at least eight workers online on weekdays from 6:00 AM to 9:00 AM in
Denver time while still allowing the Prometheus queue-depth trigger to scale
higher when needed:

```yaml
spec:
  replicas: 0
  autoscaling:
    enabled: true
    minReplicas: 0
    maxReplicas: 20
    cooldownPeriodSeconds: 300
    prometheus:
      serverAddress: http://victoriametrics:8428
      instanceNamePrefix: remote-execution
    cron:
      - name: weekday-morning-floor
        timezone: America/Denver
        start: "0 6 * * 1-5"
        end: "0 9 * * 1-5"
        desiredReplicas: 8
```

Keep `start` and `end` distinct. For scale-to-zero outside the window, set
`minReplicas: 0` and use a positive `desiredReplicas` in the cron trigger.

The generated query watches the scheduler queue for the pool's
`config.generated.sizeClass` and `config.generated.instanceNamePrefix`. Set
`autoscaling.prometheus.sizeClass` or `autoscaling.prometheus.instanceNamePrefix`
only to watch a different queue.

For a fully custom KEDA `ScaledObject`, disable operator-managed autoscaling and
replica management:

```yaml
spec:
  manageReplicas: false
```

Omit the `spec.autoscaling` block entirely. The CRD requires
`autoscaling.prometheus` whenever `autoscaling` is present, so
`autoscaling: {enabled: false}` on its own is rejected — if you want to keep the
block for documentation, keep its `prometheus` section too.

With that setting, the operator still manages the worker Deployment template and
config, but it preserves `Deployment.spec.replicas` for an external HPA or KEDA
`ScaledObject`.

### Private pools

A pool serves a single tenant when its workers register under that tenant's
instance name:

```yaml
spec:
  config:
    generated:
      instanceNamePrefix: 3f6c1d2e-8b4a-4c7e-9a1d-5e2f7b9c0a14
      platformProperties:
        - name: pool
          value: private-linux-x86-64
```

`bb_worker` then receives only operations whose instance name starts with the
prefix, compared as whole `/`-separated components. The empty default serves
every instance name. The operator rejects a prefix `bb_worker` would refuse: a
leading, trailing, or repeated `/`, or a component that REv2 reserves (`blobs`,
`uploads`, `compressed-blobs`, `actions`, `actionResults`, `operations`,
`capabilities`). Predeclare the queue in the Buildbarn scheduler with the same
prefix, platform, and size classes, as described under
[Scaling to zero](#scaling-to-zero). A custom `worker-common.libsonnet` supplied
through `commonItems` must copy `config.instanceNamePrefix` onto its runners
itself.

### Scaling to zero

`minReplicas: 0` (or `idleReplicas: 0`) needs a matching entry in the Buildbarn
scheduler's `predeclaredPlatformQueues`, with the same instance name prefix,
platform properties, and size classes as the pool. Without one, the scheduler
removes the pool's platform queue after the last worker leaves, once
`platformQueueWithNoWorkersTimeout` elapses (15 minutes by default). From then
on it rejects every action for that platform with `No workers exist` before
counting it, so the queue-depth query stays at zero and KEDA never scales the
pool back up. A cron window only restores capacity during the window. Either
predeclare the queue or keep `minReplicas` at 1 or more. The
[sample worker pools](https://github.com/Hermetiq/hermetiq-k8s/blob/main/custom-values/rbeworkers/README.md#scale-up-from-zero)
show the Buildbarn values and how to match them to each pool.

### Tuning generated autoscaling

Each `RbeWorker` with `autoscaling.enabled: true` gets a KEDA `ScaledObject`
whose Prometheus trigger measures queued-or-executing tasks for that pool's
platform:

```text
tasks_scheduled_total - tasks_executing_duration_seconds_count
```

Set `prometheus.threshold` to the pool's
`config.generated.concurrency`: the metric is work items and the threshold is
work items per replica. The generated query smooths the result with
`avg_over_time(...[queryWindow:queryResolution])`.

| Setting | Controls | Use it when |
|---|---|---|
| `prometheus.queryWindow` | Signal smoothing and therefore the target size seen by HPA | The queue is noisy and some underestimation is acceptable |
| `prometheus.queryResolution` | Subquery step within the smoothing window | The window needs more or fewer samples |
| `advanced...scaleUp.stabilizationWindowSeconds` | Minimum recommendation observed during the window | Short spikes should be ignored entirely |
| `advanced...scaleUp.policies` | Rate at which replicas may be added | The pool should climb more gradually |
| `advanced...scaleUp.selectPolicy` | Whether the larger or smaller policy wins | Normally `Max` for responsive scale-up |
| `pollingIntervalSeconds` | KEDA query frequency | Faster reaction is worth more query load |

To slow the climb without changing the eventual replica target, tune
`scaleUp.policies`. Increasing `queryWindow` is not a pure throttle: averaging
a sudden queue spike understates the backlog and can make HPA converge on too
few workers. A nonzero scale-up stabilization window delays all scale-up after
an idle recommendation because HPA chooses the minimum recommendation in that
window.

The defaults intentionally favor fast scale-up and conservative
scale-down:

| Setting | Default |
|---|---|
| `queryWindow` | `1m` |
| `queryResolution` | `15s` |
| `scaleUp.stabilizationWindowSeconds` | `0` |
| `scaleUp.selectPolicy` | `Max` |
| `scaleUp.policies` | 8 pods/15s and 100%/15s |
| `pollingIntervalSeconds` | `30` |
| scale-down | cooldown plus `Min` of 2 pods or 50% per 60s |

Queued tasks already block a client, while an early scale-up costs only the
additional pods until conservative scale-down reclaims them. Preserve that
asymmetry unless node or license capacity requires stricter pacing.

Example rate-limited scale-up:

```yaml
spec:
  autoscaling:
    pollingIntervalSeconds: 10
    prometheus:
      threshold: "11" # match config.generated.concurrency
      queryWindow: 1m
    advanced:
      horizontalPodAutoscalerConfig:
        behavior:
          scaleUp:
            stabilizationWindowSeconds: 0
            selectPolicy: Max
            policies:
              - type: Pods
                value: 4
                periodSeconds: 30
              - type: Percent
                value: 50
                periodSeconds: 30
          scaleDown:
            stabilizationWindowSeconds: 900
            selectPolicy: Min
            policies:
              - type: Pods
                value: 2
                periodSeconds: 60
```

With `Max`, the absolute policy governs small pools and the percentage policy
allows larger pools to grow faster. Remove the percentage policy for a hard
replica-per-period cap. Before pacing more aggressively, check whether pending
Pods are actually waiting for cluster autoscaler node provisioning; HPA cannot
remove that bottleneck.

### Diagnose a pool that does not scale

```bash
kubectl -n hermetiq get hpa
kubectl -n hermetiq describe scaledobject <worker-name>
kubectl -n hermetiq get scaledobject <worker-name> \
  -o jsonpath='{.spec.triggers[0].metadata.query}'
```

If the HPA target is above threshold but replicas stay flat, inspect scale-up
stabilization and `selectPolicy`. If the target itself remains unexpectedly
low, run the generated query both with and without `avg_over_time(...)`; a
large difference means the smoothing window is hiding the backlog.

## Security Context

The manager pod meets the Pod Security Standards `restricted` profile and the
CIS Kubernetes Benchmark v2.0.1 securityContext recommendations:
- UID/GID 65532, the image's distroless nonroot user
- `seccompProfile: RuntimeDefault`
- `allowPrivilegeEscalation: false` and `privileged: false`
- `readOnlyRootFilesystem: true`
- all capabilities dropped

On OpenShift, set `podSecurityContext.runAsUser` and
`podSecurityContext.runAsGroup` to `null` so the `restricted-v2` SCC can assign
them.

The worker pods the operator creates are configured on each `RbeWorker`. FUSE
build directories and Docker-in-Docker need privileged containers, while the
manager Pod keeps its restricted security context. The shared ConfigMap,
scheduler address, and generated queue query assume workers run in the
Buildbarn namespace, as described in [Install](#install).

## RbeWorker Spec Policy

The operator creates worker Deployments and `ScaledObject`s with its own
credentials, so anyone who can edit an `RbeWorker` could otherwise use them to
run pods with privileges they do not have. Starting with operator v0.3.13, an
`RbeWorker` whose spec goes beyond `specPolicy` gets `Ready=False` with reason
`SpecInvalid`.

These are always allowed: privileged worker and runner containers, FUSE at
`/dev/fuse`, and the operator's own volume-init, fuse-cleanup and Docker
containers. Use namespace Pod Security admission to limit those further. An
`RbeWorker` can never run as the operator's own ServiceAccount, and `hostPath`
paths containing `..` are always refused.

| Value | Default | Allows |
| --- | --- | --- |
| `specPolicy.allowedPodServiceAccounts` | `[]` | `spec.pod.serviceAccountName` values besides `default`. Mounting a ServiceAccount token, with `automountServiceAccountToken: true` or a projected `serviceAccountToken` volume, also needs the pod's ServiceAccount listed, including `default`. `"*"` allows any. |
| `specPolicy.allowPrivilegedExtraContainers` | `false` | `privileged: true`, `capabilities.add`, or a non-default `procMount` in `spec.pod.extraContainers` and `extraInitContainers`. |
| `specPolicy.allowedHostPathPrefixes` | `[/mnt/stateful_partition/kube-ephemeral-ssd]` | Node paths for `hostPath` volumes in `spec.pod.extraVolumes`, `spec.storage.workerVolume`, `spec.storage.casVolume` and `spec.docker.dind.storageVolume`, and a `spec.storage.fuse` device other than a `CharDevice` at `/dev/fuse`. A prefix matches itself and the paths below it, by whole path components. |
| `specPolicy.allowedClusterTriggerAuthentications` | `[]` | KEDA `ClusterTriggerAuthentication` names that `spec.autoscaling.prometheus.authenticationRef` and `additionalTriggers[].authenticationRef` may reference. `"*"` allows any. Namespaced `TriggerAuthentication` references are always allowed. |
| `specPolicy.checkExistingRbeWorkers` | `true` | Fails `helm install` and `helm upgrade` when existing `RbeWorker` objects would stop reconciling. See [Upgrading to 0.3.11](#upgrading-to-0311). |

The default `hostPath` prefix is where GKE mounts ephemeral local SSDs, which
pools use for a node-local CAS cache. Set it to `[]` to refuse every
`hostPath`, or replace it with your own node layout:

```yaml
specPolicy:
  allowedHostPathPrefixes:
    - /mnt/disks/ssd0
```

The chart passes these settings to the manager as environment variables
(`ALLOWED_POD_SERVICE_ACCOUNTS`, `ALLOW_PRIVILEGED_EXTRA_CONTAINERS`,
`ALLOWED_HOST_PATH_PREFIXES`, `ALLOWED_CLUSTER_TRIGGER_AUTHENTICATIONS`) rather
than flags, and sets `POD_SERVICE_ACCOUNT` so the operator knows its own
ServiceAccount. Operator images older than v0.3.13 ignore the variables, so
the values are safe to set before the image changes.

### Keeping the previous behavior

To upgrade without changing which `RbeWorker` specs the operator accepts, allow
everything the policy can allow. This matches operator v0.3.12 and earlier,
except that the operator's own ServiceAccount and `hostPath` paths containing
`..` stay refused:

```yaml
specPolicy:
  allowedPodServiceAccounts: ["*"]
  allowPrivilegedExtraContainers: true
  allowedHostPathPrefixes: ["/"]
  allowedClusterTriggerAuthentications: ["*"]
```

Use it as a stepping stone rather than a long-term setting. After the upgrade,
list what your pools actually use and narrow each value to that:

```bash
kubectl get rbeworkers -A -o json | jq -r '.items[] |
  "\(.metadata.namespace)/\(.metadata.name)\tsa=\(.spec.pod.serviceAccountName // "default")\thostPaths=\([.spec.storage.casVolume, .spec.storage.workerVolume, .spec.docker.dind.storageVolume, (.spec.pod.extraVolumes // [])[]] | map(select(. != null) | .hostPath.path // empty) | join(","))"'
```

Then rerun `helm upgrade` with the narrower values. The upgrade check refuses
any value that would make an existing `RbeWorker` `SpecInvalid`.

## RBAC Scope

By default, the operator watches all namespaces and uses a manager
`ClusterRole` and `ClusterRoleBinding`:

```yaml
rbac:
  mode: cluster
```

For an install managed entirely within one namespace, use:

```yaml
rbac:
  mode: namespace
metrics:
  secure: false
```

This renders a manager `Role`/`RoleBinding`, a leader-election
`Role`/`RoleBinding`, and namespaced RbeWorker admin/editor/viewer Roles. It
omits all ClusterRoles and ClusterRoleBindings. The manager automatically
watches only the release namespace (honoring `namespaceOverride`); an explicit
`watchNamespace` must match. Secure metrics uses the cluster-scoped
`TokenReview` and `SubjectAccessReview` APIs, so namespace mode requires
`metrics.secure=false` or disabling the metrics endpoint. To disable it, set
`metrics.enabled=false` and `metrics.service.enabled=false`, plus any enabled
scrape resources. With HTTP metrics, control access through your cluster's
network policy or monitoring setup.

`watchNamespace` renders as `--watch-namespace`, so it needs an operator image
that accepts that flag; older images exit with
`flag provided but not defined`. Change it together with `image.tag` and update
or clear `image.digest`; a digest takes precedence over the tag.

`rbac.managerBindingMode` is retained for existing installs in cluster mode.
Its `namespace` option binds a **ClusterRole** within one namespace and still
creates other cluster-scoped RBAC resources. Use `rbac.mode=namespace` when
the installer cannot create ClusterRoles. In cluster mode, setting
`watchNamespace` narrows the watch without narrowing the grant.

To manage `RbeWorker` resources across several namespaces, keep
`rbac.mode=cluster`, `rbac.managerBindingMode=cluster`, and `watchNamespace`
empty. The operator watches one namespace or all namespaces, not an arbitrary
list of namespaces. Each `RbeWorker` must still share a namespace with the
Buildbarn installation it uses.

Switching an existing release to namespace mode removes its old ClusterRoles
and ClusterRoleBindings, so that upgrade requires permission to delete them.
The `RbeWorker` CRD also needs cluster-level installation; a platform team can
install it separately before a namespace-scoped chart install.

To manage all RBAC outside the chart, set `rbac.create=false` and supply
`serviceAccount.name`.

## Observability

The controller exposes secure controller-runtime metrics on port `8443` by
default and can export operator-owned metrics and logs with OTLP:

```yaml
otel:
  metrics:
    enabled: true
  logs:
    enabled: true
  endpoint: otel-collector.observability.svc.cluster.local:4317
  insecure: true
  resourceAttributes: service.namespace=buildbarn,deployment.environment=prod
```

`otel.serviceName` sets the exported service name and defaults to the Helm
fullname.

`metrics.serviceMonitor.enabled` and `metrics.vmServiceScrape.enabled` are
available for clusters that install the Prometheus Operator or VictoriaMetrics
Operator CRDs.

The chart does not create ConfigMaps or Secrets consumed by the controller.
If `metrics.cert.existingSecret` or another externally supplied Secret changes,
change a value under `podAnnotations` in the operator values file on the next
Helm upgrade to restart the controller, for example:

```yaml
podAnnotations:
  hermetiq.com/external-secret-revision: "2026-09-30-1"
```

With `metrics.secure=true`, the default, the metrics endpoint rejects
unauthenticated scrapes with `401`. Both scrape objects therefore send the
scraping pod's ServiceAccount token by default through
`metrics.<scrape>.bearerTokenFile`, and that ServiceAccount must be bound to
the ClusterRole created by `rbac.metricsReader.create`. Use
`metrics.<scrape>.authorization` to supply a different credential, or set
`bearerTokenFile: ""` to scrape without one.

## Local chart development

OCI releases are the supported customer path. From the repository root,
contributors can render the checked-out chart, including its CRD, with:

```bash
helm lint ./charts/bb-worker-operator
helm template bb-worker-operator ./charts/bb-worker-operator \
  --namespace hermetiq \
  --include-crds
```

## License

The chart source in this package is licensed under the Apache License 2.0;
see the packaged `LICENSE` file. The operator image it deploys is proprietary
software distributed under the
[Hermetiq Software License Agreement](https://github.com/Hermetiq/hermetiq-k8s/blob/main/charts/hermetiq/SOFTWARE-LICENSE-AGREEMENT.md).
