# RBE worker manifests

This directory is a Kustomize base for the standard Ubuntu, Codex, and Envoy
worker pools. Apply it directly when the starter service addresses and project
ID are correct:

```bash
kubectl apply --namespace hermetiq --kustomize custom-values/rbeworkers
```

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
the Buildbarn chart, so apply them after the Buildbarn release is ready. Pools
that should emit completed-action events must point
`spec.config.generated.completedActionLoggerAddress` at the Hermetiq publisher;
the starter value `bep-nats-pub.hermetiq.svc.cluster.local:50091` matches
`bbcal.address` in `custom-values/buildbarn-values.yaml`. Adjust node labels,
tolerations, platform properties, runner images, and resource sizes to match
your environment.

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
        path: /spec/autoscaling/prometheus/projectID
        value: example-project
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
```

The JSON Patch `replace` operations intentionally fail if a future manifest no
longer contains one of these fields, preventing an overlay from silently
leaving a worker pointed at the starter environment.

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
so the optional workers receive the same environment-specific addresses and
project ID as the standard bundle.
