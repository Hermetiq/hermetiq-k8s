# RBE worker manifests

This directory is a Kustomize base for the standard Ubuntu, Codex, and Envoy
worker pools. Apply it directly when the starter service addresses and project
ID are correct:

```bash
kubectl apply --namespace hermetiq --kustomize custom-values/rbeworkers
```

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

The size-class and Testcontainers manifests are intentionally excluded from
the standard bundle. Apply them only after satisfying the scheduler, node-pool,
and container-runtime prerequisites documented in the repository README. Add
any combination to the environment overlay with `components`:

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
