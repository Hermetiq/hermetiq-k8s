# Migrating the BB Worker Operator chart to 1.0.0

This guide is for an operator release on chart `0.3.12` or earlier. A new
installation needs none of it: follow the
[chart README](../charts/bb-worker-operator/README.md#install) instead. The
operator upgrade is one part of the `1.0.0` bundle cut-over; read
[Migrating to 1.0.0](migrate-to-1.0.0.md) first for the order across the
Hermetiq, BB Worker Operator and Buildbarn charts.

Which sections apply depends on the chart you run today:

| Running | Follow |
|---|---|
| `0.3.12` | [Upgrading to 1.0.0](#upgrading-to-100) |
| `0.3.11` | The above, and [Upgrading to 0.3.12](#upgrading-to-0312) |
| `0.3.10` or earlier | The above, and [Upgrading to 0.3.11](#upgrading-to-0311) |
| A release before `0.3.4` | The above, and [Releases before 0.3.4](#releases-before-034) |

An operator release that embedded the completed-action logger address in the
generated Jsonnet also needs the staging step under
[Completed-action logger address](#completed-action-logger-address).

## Upgrading to 1.0.0

Chart 1.0.0 follows 0.3.12; the chart version now moves together with the
Hermetiq and Buildbarn charts, and no chart was published in between. It
deploys operator v1.0.0, which generates worker configuration for Buildbarn's
content-defined chunking (CDC) storage and nothing else. Run it only with the
Buildbarn 1.0.0 chart. Against an older Buildbarn release a worker stops at
startup with `common.libsonnet is not a CDC Buildbarn configuration`.

Upgrade the operator inside the Buildbarn
[cut-over window](migrate-to-1.0.0-buildbarn.md#storage-format-cutover-and-rollback),
after the worker pools are paused and before the Buildbarn upgrade. Nothing
enforces the order. The Buildbarn chart does not check which operator is
running: an operator older than v1.0.0 generates pre-CDC worker
configuration, the CDC `bb-worker` rejects it, and the pools crash-loop until
the operator is upgraded.

- Apply the 1.0.0 CRD first, as described under
  [CRD Lifecycle](../charts/bb-worker-operator/README.md#crd-lifecycle).
  `spec.images.worker` and `spec.images.runnerInstaller` become optional: when
  unset, the operator uses the `workerImage` and `runnerInstallerImage` keys of
  the referenced config ConfigMap, which the Buildbarn chart publishes, so
  worker images follow the Buildbarn release.
- Before the Buildbarn upgrade, remove pre-CDC image pins from each
  `RbeWorker` or update them to the CDC images. The Buildbarn chart refuses
  to upgrade while a live `RbeWorker` pins a pre-CDC image. A pool without
  pins reports `SpecInvalid` until Buildbarn 1.0.0 has published the two
  keys; with the pools paused that has no effect.
- The [sample worker pools](../custom-values/rbeworkers/README.md) carry no
  image pins. For an existing installation, apply them inside the cut-over
  window with the worker pools paused: upgrade the CRD and the operator, apply
  the unpinned manifests, then upgrade Buildbarn.
- The embedded `worker-common.libsonnet` changed, so every generated-config
  worker pool is rolled as soon as the new operator reconciles it, on every
  pool at once. A pool that is not paused restarts its workers into the new
  configuration; actions that outlast the pod's termination grace period are
  killed (see
  [Draining actions on termination](../charts/bb-worker-operator/README.md#draining-actions-on-termination)).
  A pool with `spec.config.rolloutOnChange: false` is not rolled and picks the
  new file up when its Pods next restart.
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
- Rolling Buildbarn back to a pre-CDC chart means rolling this chart back to
  0.3.12 as well, because operator v1.0.0 cannot generate pre-CDC worker
  configuration. The pre-CDC Buildbarn chart does not publish `workerImage`
  and `runnerInstallerImage`, so set `spec.images.worker` and
  `spec.images.runnerInstaller` back to the pre-CDC images on each
  `RbeWorker` as part of the rollback.
- A pool that projects its own copy of `worker-common.libsonnet` through
  `commonItems` is read by the Buildbarn chart's configuration text check like
  any other worker configuration, and is refused if it contains pre-CDC
  fields. Replace a copy taken from an older operator with one based on this
  operator's built-in file. The same applies to custom pools that use
  `spec.config.files`, and to the `workerImage` and `runnerInstallerImage`
  defaults of a custom ConfigMap: removing a pin from the `RbeWorker` does not
  update a separate ConfigMap. See
  [What the upgrade checks cover](migrate-to-1.0.0-buildbarn.md#what-the-upgrade-checks-cover).

When upgrading from 0.3.11 or earlier, also follow
[Upgrading to 0.3.12](#upgrading-to-0312).

## Upgrading to 0.3.12

Chart 0.3.12 deploys the same operator v0.3.13 as 0.3.11 and has the same
CRD. The default image is now pinned to its SHA-256 manifest digest, so the
operator Deployment rolls once on upgrade. Worker pools are not restarted.

`image.digest` takes precedence over `image.tag`. If you override `image.tag`,
also set `image.digest` to that image's digest, or clear it with
`--set-string image.digest=`. Otherwise the operator keeps running the pinned
image. See [image integrity](image-integrity.md).

When upgrading from 0.3.10 or earlier, also follow
[Upgrading to 0.3.11](#upgrading-to-0311).

## Upgrading to 0.3.11

Chart 0.3.11 deploys operator v0.3.13, which stops reconciling an `RbeWorker`
in two new cases. It sets `Ready=False` and leaves that pool's existing
Deployment and `ScaledObject` as they are, so running workers keep running and
autoscaling, but changes to the `RbeWorker` no longer reach them:

- **`SpecInvalid`**: the spec asks for something the
  [RbeWorker Spec Policy](../charts/bb-worker-operator/README.md#rbeworker-spec-policy)
  does not allow, such as a `hostPath` CAS volume outside the allowed prefixes.
- **`NameConflict`**: a Deployment, generated ConfigMap or `ScaledObject` with
  the pool's name exists but is not controlled by this `RbeWorker`, or
  `spec.config.generated.commonConfigMapName` is `<name>-config`. Objects the
  operator created already carry the right owner reference. A conflict usually
  means the `RbeWorker` was deleted with `--cascade=orphan` and recreated.

To catch both before they happen, `helm install` and `helm upgrade` list the
`RbeWorker` objects the operator watches and fail with each problem and the
fix. Widen `specPolicy` or fix the `RbeWorker` objects, then rerun the
upgrade. The check, its permissions, and the dry-run command that shows the
result without changing anything are described under
[Install-time check](../charts/bb-worker-operator/README.md#install-time-check).

The chart passes the policy to the manager as environment variables. Operator
images older than v0.3.13 ignore them, so the `specPolicy` values are safe to
set before the image changes.

Pools that use Docker-in-Docker restart once during the upgrade, because dockerd
now runs as a Kubernetes-native sidecar (Kubernetes 1.29 or newer). Other pools
keep their pod template. Apply the target release's CRD first as described in
[CRD Lifecycle](../charts/bb-worker-operator/README.md#crd-lifecycle), which
adds the
[FUSE kernel tunables](../charts/bb-worker-operator/README.md#kernel-tunables).
A pool that does not set the tunables keeps the worker configuration it had
before.

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

## Releases before 0.3.4

If upgrading from a release before 0.3.3, the target release's CRD includes
updated Pod and volume schemas. If upgrading from a release before 0.3.4,
remove `spec.autoscaling.prometheus.projectID` from `RbeWorker` manifests and
Kustomize patches before reapplying them; the CRD no longer accepts that field.
Generated queries now use the `RbeWorker` namespace, so each worker must share
a namespace with the Buildbarn scheduler it scales on.

## Completed-action logger address

The operator passes `spec.config.generated.completedActionLoggerAddress` to the
worker container as the `BBCAL_ADDRESS` environment variable, which the
generated Jsonnet reads; see
[Completed-action logger address](../charts/bb-worker-operator/README.md#completed-action-logger-address).

When upgrading from an operator release that embedded the address in the
generated Jsonnet, first add `BBCAL_ADDRESS` to `spec.worker.env` with the
current address (or an empty value to keep logging disabled) and let that
rollout finish before upgrading the operator. Generated ConfigMaps are updated
in place, so this staging lets an old Pod still restart successfully after its
Jsonnet starts reading the environment. Afterward you can remove the explicit
entry and use `completedActionLoggerAddress` again.
