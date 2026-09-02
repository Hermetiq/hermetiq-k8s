# bb-worker-operator

Installs the Buildbarn worker operator and the `rbeworkers.bb.hermetiq.com` CRD.

## Install

```bash
helm upgrade --install bb-worker-operator ./charts/bb-worker-operator \
  --namespace bb-worker-operator-system \
  --create-namespace \
  --set image.repository=<registry>/bb-worker-operator \
  --set image.tag=<version>
```

The chart places the RbeWorker CRD in `crds/`, so Helm installs it before the
controller on a first-time `helm install`.

## CRD Lifecycle

The RbeWorker CRD intentionally lives in the chart's top-level `crds/` directory:

```text
charts/bb-worker-operator/crds/bb.hermetiq.com_rbeworkers.yaml
```

This gives the right bootstrap behavior for new clusters: Helm installs CRDs
from `crds/` before rendering or applying templates, so the operator can start
watching `RbeWorker` resources after installation.

`helm template` does not include CRDs by default. When rendering a complete
install bundle, include them explicitly:

```bash
helm template bb-worker-operator ./charts/bb-worker-operator \
  --namespace bb-worker-operator-system \
  --include-crds
```

For upgrades, manage CRD changes as an explicit step. Helm installs CRDs from
`crds/`, but it does not upgrade or delete them during `helm upgrade`. Apply
updated CRDs intentionally before applying any `RbeWorker` custom resources that
depend on the new schema.

The rename from `workers.bb.hermetiq.com` to `rbeworkers.bb.hermetiq.com` is a
replacement, not an in-place upgrade path. Delete the old `Worker` CRD and roll
out a controller image built with the `RbeWorker` API before creating new
`RbeWorker` custom resources.

Do not move the CRD into `templates/` just to make it appear in default
`helm template` output. Keeping CRDs in `crds/` preserves Helm's install-order
semantics and avoids mixing cluster-scoped API lifecycle with the controller's
normal namespaced release resources.

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
      projectID: hermetiq
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

## RBAC Scope

By default, the operator's manager `ClusterRole` is granted with a
`ClusterRoleBinding`:

```yaml
rbac:
  managerBindingMode: cluster
```

Use this mode when the operator should manage `RbeWorker` resources, generated
Deployments, ConfigMaps, and KEDA `ScaledObject` resources across multiple
namespaces.

For a single-namespace install, bind the same manager `ClusterRole` with a
namespaced `RoleBinding` and scope the manager's watch to match:

```yaml
rbac:
  managerBindingMode: namespace
watchNamespace: <release namespace>
```

Both halves are required. The `RoleBinding` only authorizes the release
namespace, while an unscoped manager list/watches `RbeWorker`, `Deployment`, and
`ConfigMap` cluster-scoped — it would start, get `Forbidden` on every watch, and
reconcile nothing without failing loudly. The chart therefore requires
`watchNamespace` in this mode, and requires it to equal the release namespace
(honoring `namespaceOverride`): pointing it elsewhere has the same outcome.

`watchNamespace` renders as `--watch-namespace`, so it needs an operator image
that accepts that flag; older images exit with
`flag provided but not defined`. Change it together with `image.tag`.

Leaving `watchNamespace` empty (the default) watches every namespace, which is
what `managerBindingMode: cluster` grants. Setting it alongside
`managerBindingMode: cluster` is allowed and narrows the watch without narrowing
the grant — useful for limiting reconcile scope while keeping cluster RBAC.

The operator watches one namespace at a time. To manage `RbeWorker` resources in
several namespaces, use `managerBindingMode: cluster` and leave `watchNamespace`
empty.

If your cluster policy forbids a `ClusterRoleBinding` and you would rather bind
permissions yourself, set `rbac.create: false` and supply `serviceAccount.name`;
the chart then validates nothing about the watch scope.

The secure metrics auth binding remains cluster-scoped when enabled because
Kubernetes `TokenReview` and `SubjectAccessReview` are not namespace-scoped
worker-management permissions.

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

`metrics.serviceMonitor.enabled` and `metrics.vmServiceScrape.enabled` are
available for clusters that install the Prometheus Operator or VictoriaMetrics
Operator CRDs.
