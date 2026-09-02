# Buildbarn Size-Class Worker Pools (ISCC)

Buildbarn can learn which worker size is good enough for a given action shape. That lets you send cheap, predictable work to smaller workers and reserve larger workers for actions that need them.

The storage piece behind this is the **Initial Size Class Cache**, or ISCC. The scheduler records previous outcomes for an action shape and uses that history to choose the initial worker size class next time. If an action fails on a smaller class, Buildbarn falls back to the largest class.

A size class is just a positive integer relative to other workers serving the same platform. We recommend using CPU cores as the meaning, because it is easy for people to reason about later.

The ISCC key is a reduced action digest: command digest plus platform. It intentionally ignores the input root, timeout, and `do_not_cache`. In practice, that means it learns from repeated actions with the same command/platform shape, not from every source-file change.

## 1. Enable ISCC Storage

ISCC is an extra bb-storage store served by the storage pod. It is disabled by default and is configured like the other stores.

```yaml
storage:
  persistence:
    iscc:
      enabled: true
      # backend / blockDevice / size like the other stores.
      # Sizing: buildbarn-storage-model.md
      # Raw devices: buildbarn-block-storage.md
```

On a PVC-backed release, enabling ISCC or FSAC adds a claim to the storage StatefulSet's `volumeClaimTemplates`. Kubernetes cannot update that in place. The `helm upgrade` fails until you delete the StatefulSet and run it again; existing `cas` and `ac` PVCs are retained and reattached.

FSAC, the File System Access Cache, is the sibling store used for input prefetching. Enable it with:

```yaml
storage:
  persistence:
    fsac:
      enabled: true
```

FSAC is currently consumed by the chart's worker Jsonnet prefetching path when a chart-managed worker has `<worker>.config.prefetching.enabled: true` and `virtualBuildDirectory.enabled: true`. The generated `RbeWorker` CRD path exposes size classes and Docker modes, but not a direct prefetching field today, so the examples here focus on the ISCC scheduler path.

## 2. Enable Scheduler Analysis

Turn on the feedback-driven analyzer and predeclare the multi-size-class queue for the platform you want to route.

```yaml
scheduler:
  sizeClassAnalysis:
    enabled: true
  predeclaredPlatformQueues:
    - platform:
        - name: pool
          value: sizeclass
      sizeClasses: [1, 2]
```

`sizeClasses` must be positive and increasing. The largest class is special: it retries actions that failed on smaller classes, so it needs to be capable of running the full workload.

`predeclaredPlatformQueues` is required for multiple size classes. It keeps one queue alive per class even when a class temporarily has no workers, and it tells the scheduler which class is the largest retry class.

The platform properties and size classes here must exactly match the worker pools below.

## 3. Create Matching Worker Pools

A worker's size class is `runners[].sizeClass`. With the bb-worker-operator, the chart exposes that as `spec.config.generated.sizeClass` on an `RbeWorker`.

Deploy at least two pools with the same platform and different size classes. This repository ships complete examples in `custom-values/rbeworkers/optional/sizeclass/worker-sizeclass-small.yaml` and `custom-values/rbeworkers/optional/sizeclass/worker-sizeclass-large.yaml`:

```yaml
apiVersion: bb.hermetiq.com/v1
kind: RbeWorker
metadata:
  name: worker-sizeclass-small
  namespace: hermetiq
spec:
  config:
    generated:
      commonConfigMapName: buildbarn-worker-config
      completedActionLoggerAddress: bep-nats-pub.hermetiq.svc.cluster.local:50091
      platformProperties:
        - name: pool
          value: sizeclass
      sizeClass: 1 # the large pool sets sizeClass: 2
      concurrency: 4
      virtualBuildDirectory:
        filePoolPath: /storage-worker-cas/file_pool
        filePoolSizeBytes: 34359738368
        maximumFilePoolFileCount: 200000
        maximumFilePoolSizeBytes: 25769803776
    rolloutOnChange: true
  replicas: 0
  autoscaling:
    enabled: true
    minReplicas: 0
    maxReplicas: 10
    prometheus:
      serverAddress: http://vmselect-vmks.hermetiq.svc.cluster.local:8481/select/0/prometheus
      projectID: "0"
      sizeClass: "1" # the large pool sets sizeClass: "2"
      threshold: "4"
  # images is required by the CRD. Copy images.runner, images.worker, pod,
  # runner, storage, and worker settings from your base worker pool, for
  # example rbeworkers/worker-ubuntu22-04.yaml.
```

Important details:

- Do not list `worker-common.libsonnet` under `commonItems`. The operator projects its own copy. `commonItems` defaults to `[common.libsonnet]`, which is what you want.
- Keep `completedActionLoggerAddress` aligned with the BEP publisher service for your Hermetiq deployment. The value above matches the default `hermetiq` namespace; change it when deploying Hermetiq elsewhere.
- Use a distinct platform, such as `pool=sizeclass`, so these workers get their own queue. Do not mix default size class `0` workers with positive size classes in the same queue.
- Give each worker pool its own on-node CAS read-cache path, such as `cas-sizeclass-small` and `cas-sizeclass-large`. Two workers must not share one blocks file.
- If both pools run on the same node type, size classes are nominal. That is fine for testing the ISCC path. Use different machine types when you want the classes to represent real resource differences.

## Driving It

Point a build at the size-class platform:

```text
--remote_default_exec_properties=pool=sizeclass
```

With an empty ISCC, the scheduler sends every action to the largest class. That is expected and safe. The largest class is the fallback class, so the first runs favor correctness over cost.

The analyzer only learns from executions. Cache hits do not teach it anything. A one-shot build where each action runs once will populate little useful history, and a fully cached rerun will not move the model forward. Repeated real executions of the same action shapes do.

For a controlled warmup, use a build that forces repeated executions, for example:

```text
bazel test //... --nocache_test_results --runs_per_test=20
```

As history accumulates, successful smaller-class probes cause traffic to shift down.

## Verify

The scheduler is metrics-first, so expect more signal from Prometheus than from logs. Port-forward the scheduler metrics endpoint on `:9980` and check:

```text
# worker pool registered under its class
buildbarn_builder_in_memory_build_queue_workers_created_total{...,size_class="1"}

# predeclared queues exist even before every class has workers
buildbarn_builder_in_memory_build_queue_invocations_created_total{...,size_class="2"}

# traffic moves toward smaller classes as the analyzer learns
buildbarn_builder_in_memory_build_queue_tasks_scheduled_total{...,size_class="1"}
```

The first healthy pattern is largest-class traffic first, then gradual smaller-class traffic after repeated executions. Sudden remote failures usually mean the platform properties, predeclared queue, and worker size classes do not line up exactly.
