# RBE worker manifests

This directory is a Kustomize base for the standard Ubuntu, Codex, and Envoy
worker pools. After copying `custom-values/` to `my-custom-values/` and
installing Buildbarn, edit the copied manifests for your environment. Apply
them after the Buildbarn release and `buildbarn-worker-config` are ready:

```bash
kubectl apply --namespace hermetiq --kustomize my-custom-values/rbeworkers
```

These manifests require operator 0.3.4 or later, which filters queue-depth
queries by the worker's namespace. Existing `RbeWorker` manifests and overlays
must drop `spec.autoscaling.prometheus.projectID` after the upgrade.

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
  concurrently scheduled workers cannot share the same CAS cache path.
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

## Environment overlays

For another environment, reference this directory from a Kustomize overlay and
patch the environment-specific values without copying the worker manifests:

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
standard bundle. Generated queue-depth queries filter by each worker's namespace.

## Pod security

Worker pods can't meet Pod Security Standards `restricted`, because the FUSE
build directory needs privileged containers:
- The `worker` container runs privileged as root.
- The operator's `fuse-cleanup` sidecar runs privileged as root.
- Docker-in-Docker pools also run `dind` privileged.

Run the pools in a namespace of their own, labelled
`pod-security.kubernetes.io/enforce: privileged`, so the Buildbarn and Hermetiq
namespaces can enforce `restricted`. Give the pools dedicated nodes. If you restrict
Buildbarn with NetworkPolicies, allow the worker namespace. See the Buildbarn
chart README for the storage policy and the scheduler example.

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
