# BB Worker Operator Helm Chart

Installs the Buildbarn worker operator and the `rbeworkers.bb.hermetiq.com` CRD.
Use the repository's
[installation guide](https://github.com/Hermetiq/hermetiq-k8s#readme) for the
supported full-stack deployment order.

## Contents

- [Install](#install)
- [Verify](#verify)
- [CRD Lifecycle](#crd-lifecycle)
- [KEDA Autoscaling](#keda-autoscaling)
  - [Tuning generated autoscaling](#tuning-generated-autoscaling)
  - [Diagnose a pool that does not scale](#diagnose-a-pool-that-does-not-scale)
- [RBAC Scope](#rbac-scope)
- [Observability](#observability)
- [Local chart development](#local-chart-development)

## Install

```bash
helm show crds oci://ghcr.io/hermetiq/bb-worker-operator \
  --version 0.3.1 | kubectl apply --server-side -f -

helm upgrade --install --namespace hermetiq bb-worker-operator \
  oci://ghcr.io/hermetiq/bb-worker-operator \
  --version 0.3.1 \
  --values bb-worker-operator-values.yaml
```

Keep the CRD and controller image on the same release. Leave `image.tag` empty
so the image follows the chart's `appVersion`: the CRD is what accepts a field
and the controller is what acts on it, so a controller older than the CRD
silently ignores fields it does not know.

The chart places the RbeWorker CRD in `crds/`, so Helm installs it before the
controller on a first-time `helm install`.

## Verify

```bash
kubectl wait --for=condition=Established crd/rbeworkers.bb.hermetiq.com --timeout=60s
kubectl -n hermetiq rollout status deployment/bb-worker-operator --timeout=120s
kubectl -n hermetiq get rbeworkers
```

`kubectl get rbeworkers` is empty until you apply worker pools, which depend on
the `buildbarn-worker-config` ConfigMap rendered by the Buildbarn chart. Once
pools exist, each `RbeWorker` reports the Deployment, ConfigMap, and KEDA
`ScaledObject` it manages in its status.

## CRD Lifecycle

The RbeWorker CRD intentionally lives in the chart's top-level `crds/` directory:

```text
charts/bb-worker-operator/crds/bb.hermetiq.com_rbeworkers.yaml
```

This gives the right bootstrap behavior for new clusters: Helm installs CRDs
from `crds/` before rendering or applying templates, so the operator can start
watching `RbeWorker` resources after installation.

`helm template` does not include CRDs by default; pass `--include-crds` when
rendering a complete install bundle, as shown under
[Local chart development](#local-chart-development).

For upgrades, manage CRD changes as an explicit step. Helm installs CRDs from
`crds/`, but it does not upgrade or delete them during `helm upgrade`. Apply
updated CRDs intentionally before applying any `RbeWorker` custom resources that
depend on the new schema.

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
      projectID: "0" # the Hermetiq project ID
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

With `metrics.secure=true`, the default, the metrics endpoint rejects
unauthenticated scrapes with `401`. Both scrape objects therefore send the
scraping pod's ServiceAccount token by default through
`metrics.<scrape>.bearerTokenFile`, and that ServiceAccount must be bound to
the ClusterRole created by `rbac.metricsReader.create`. Use
`metrics.<scrape>.authorization` to supply a different credential, or set
`bearerTokenFile: ""` to scrape without one.

## Local chart development

OCI releases are the supported customer path. Contributors can render the
checked-out chart, including its CRD, with:

```bash
helm lint ./charts/bb-worker-operator
helm template bb-worker-operator ./charts/bb-worker-operator \
  --namespace hermetiq \
  --include-crds
```
