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
- [Security Context](#security-context)
- [RBAC Scope](#rbac-scope)
- [Observability](#observability)
- [Local chart development](#local-chart-development)
- [License](#license)

## Install

Start with the
[operator starter values](https://github.com/Hermetiq/hermetiq-k8s/blob/main/custom-values/bb-worker-operator-values.yaml),
copied to `my-custom-values/bb-worker-operator-values.yaml` as described in
the [repository setup guide](https://github.com/Hermetiq/hermetiq-k8s#prepare-custom-values).

Inspect this release's packaged documentation and defaults before editing the
operator values:

```bash
helm show readme oci://ghcr.io/hermetiq/bb-worker-operator --version 0.3.5
helm show values oci://ghcr.io/hermetiq/bb-worker-operator --version 0.3.5
```

For a namespace-scoped install, set `rbac.mode=namespace` and
`metrics.secure=false` in the values file. Have a cluster administrator apply
the CRD from the matching release tag:

```bash
kubectl apply --server-side -f \
  https://raw.githubusercontent.com/Hermetiq/hermetiq-k8s/bb-worker-operator-v0.3.5/charts/bb-worker-operator/crds/bb.hermetiq.com_rbeworkers.yaml
kubectl wait --for=condition=Established crd/rbeworkers.bb.hermetiq.com --timeout=60s
```

Then install the controller in the namespace:

```bash
helm upgrade --install --namespace hermetiq bb-worker-operator \
  oci://ghcr.io/hermetiq/bb-worker-operator \
  --version 0.3.5 \
  --skip-crds \
  --values my-custom-values/bb-worker-operator-values.yaml
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

When `podDisruptionBudget.enabled=true`, the chart sets
`unhealthyPodEvictionPolicy: AlwaysAllow`. Node drains can evict an unready
operator Pod even when its healthy Pod budget is exhausted.

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

Release 0.3.3 refreshes the embedded Kubernetes Pod and volume schemas in the
`RbeWorker` CRD for the operator's Kubernetes v0.37 dependencies. Apply the
0.3.3 CRD before upgrading the operator image, using the versioned CRD YAML
from that release tag as shown in [Install](#install).

Release 0.3.4 removes `spec.autoscaling.prometheus.projectID`. Generated
queries now filter on the `RbeWorker`'s own namespace, so the worker must live
in the same namespace as the Buildbarn scheduler it scales on. After applying
the 0.3.4 CRD, delete `projectID` from every `RbeWorker` manifest and Kustomize
patch; `kubectl apply` rejects it as an unknown field.

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
build directories and Docker-in-Docker need privileged containers. Create
`RbeWorker` resources in the same namespace as their Buildbarn installation;
the shared ConfigMap, scheduler address, and generated queue query all assume
this placement. That namespace must permit privileged worker Pods (for example,
with `pod-security.kubernetes.io/enforce: privileged`). The manager Pod keeps
its restricted security context. For `rbac.mode=namespace`, install the
operator in the Buildbarn namespace so it watches those `RbeWorker` resources.

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
`flag provided but not defined`. Change it together with `image.tag`.

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

OCI releases are the supported customer path. Contributors can render the
checked-out chart, including its CRD, with:

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
