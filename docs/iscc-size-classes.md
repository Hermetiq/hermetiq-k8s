# Buildbarn Size-Class Worker Pools (ISCC)

Buildbarn can learn which worker size is good enough for a given action shape. That lets you send cheap, predictable work to smaller workers and reserve larger workers for actions that need them.

The storage piece behind this is the **Initial Size Class Cache**, or ISCC. The scheduler records previous outcomes for an action shape and uses that history to choose the initial worker size class next time. If an action fails on a smaller class, Buildbarn falls back to the largest class.

A size class is just a positive integer relative to other workers serving the same platform. We recommend using CPU cores as the meaning, because it is easy for people to reason about later.

The ISCC key is a reduced action digest: command digest plus platform. It intentionally ignores the input root, timeout, and `do_not_cache`. In practice, that means it learns from repeated actions with the same command/platform shape, not from every source-file change.

## 1. Enable ISCC Storage

ISCC is a bb-storage store served by the storage pod. It is enabled by default
and uses a persistent index for both filesystem storage
(`keyLocationMap.type: blockDevice`) and raw blocks (`blockDevice.keyLocationMap: file`).
Remove any old explicit `inMemory` override, or apply the
[persistent profile](buildbarn-storage-operations.md#migrate-to-persistent-indexes)
after deployment values. Both profiles preserve explicit ISCC and FSAC enable
flags. Set `storage.persistence.iscc.enabled: false` if unused. The
[ephemeral opt-out](buildbarn-storage-operations.md#explicit-ephemeral-opt-out)
deliberately discards learned history on storage-process restart.

```yaml
storage:
  persistence:
    iscc:
      enabled: true
      keyLocationMap:
        type: blockDevice # default for filesystem backend; preserve learned history
      # backend / blockDevice / size like the other stores.
      # Sizing: buildbarn-storage-model.md
      # Raw devices: buildbarn-block-storage.md
```

Because the store is on by default, each persistence mode asks something of it:

- `mode: pvc` gives it its own claim. Its class is
  `storage.persistence.iscc.storageClassName` (default `premium-rwo`), which
  does not follow the CAS class; a class the cluster does not have leaves the
  claim and its storage pod Pending.
- `mode: emptyDir` requires `storage.persistence.iscc.emptyDir.sizeLimit`.
- `mode: hostPath` with a filesystem-backed ISCC requires
  `storage.persistence.iscc.hostPath.path` to be set whenever CAS is a raw
  block device or `cas.hostPath.path` is not the chart default. Left on its
  default path next to a moved CAS, the render fails.

On a PVC-backed release, enabling a previously disabled ISCC or FSAC adds a
claim to the storage StatefulSet's `volumeClaimTemplates`. Kubernetes cannot update that in place,
and the chart refuses the upgrade before anything is applied, naming the added
claim template. Upgrading a chart 0.9.9 release that never set
`iscc.enabled` or `fsac.enabled` is the same change, because both were
disabled by default there. An added claim name is not a rolling change. Follow
[Recreate the Storage StatefulSet](buildbarn-storage-operations.md#recreate-the-storage-statefulset):
its stopped recreation scales storage to zero, so every cache request fails
until storage is back, and it describes what to do when storage cannot be
stopped. Existing PVCs are retained and reattached, and the new claim starts
empty.

Persistence requires the **blocks, key-location map, and `persistent_state`** to
survive together. Changing an `inMemory` setting cannot recover an index already
lost on restart. The first switch starts empty, then future restarts can reuse
the history. Filesystem ISCC needs
no new claim for this switch. Raw-block ISCC on `mode: pvc` adds an `iscc-meta`
claim, which is again an added claim name; follow the same
[StatefulSet recreate runbook](buildbarn-storage-operations.md#recreate-the-storage-statefulset).
That claim's class is `storage.persistence.iscc.blockDevice.metadata.storageClassName`
(default `premium-rwo`). Set it to a class whose volumes are lost together
with the blocks class, or the index can outlive its blocks.

This persistence-only change assumes the existing release already uses CDC.
Upgrading a pre-CDC release also changes the ISCC object encoding and requires
the coordinated [storage format cutover](buildbarn-storage-model.md#storage-format-cutover-and-rollback),
including a cold reset of any persistent ISCC history. The profile cannot
convert that old history in place.

The bundled [raw Local SSD overlay](../custom-values/buildbarn-values-local-ssd-block.yaml)
persists all five stores on its provisioner's same-SSD metadata LV. These are the
ISCC settings from that layout; apply the complete overlay so its readiness
selector and the other stores' metadata paths are included. Follow the
[GKE validation runbook](buildbarn-gke-storage-validation.md) when changing the
node layout. Do not substitute a boot-disk directory for the metadata mount:

```yaml
storage:
  persistence:
    mode: hostPath
    blockDevice:
      allowHostPath: true
    iscc:
      enabled: true
      backend: blockDevice
      blockDevice:
        keyLocationMap: file
        size: 2Gi
        hostPath:
          devicePath: /dev/ephemeral/iscc
        metadata:
          size: 1Gi
          keyLocationMapSizeMi: 512
          hostPath:
            path: /mnt/stateful_partition/buildbarn-local-ssd/metadata/iscc
            type: Directory
```

The metadata mount must live on the same Local SSD storage as the blocks,
with a readiness gate verifying the actual mount and a paired reset when the
LVs/VG are replaced. `blockDevice.metadata.hostPath.path` has no default: the
render fails without it. `type: Directory` is the chart default for every raw
store's metadata directory (it was `DirectoryOrCreate` before chart 0.10.0).
The kubelet does not create the directory, so a missing metadata mount fails
the volume mount and the storage pod does not start, instead of an empty index
being created on the boot disk. Pre-create the directory inside the mounted
filesystem, not at the mountpoint itself, and reserve space for the 512MiB
index and checkpoint state. `metadata.size` does not provision or limit hostPath
space, and `Directory` does not verify the underlying filesystem identity.
Retaining old metadata over wiped blocks can report nonexistent blobs as present;
it is not a safe cold cache. To survive node replacement, use durable storage
for both pieces. `storage.persistence.mode` is global, so the chart cannot put
only ISCC on PVCs while other stores use hostPath. See
[What Survives a Restart](buildbarn-storage-operations.md#what-survives-a-restart).

FSAC, the File System Access Cache, is the sibling store used for input prefetching.
It is also enabled by default; the explicit setting is:

```yaml
storage:
  persistence:
    fsac:
      enabled: true
```

`RbeWorker` pools can use FSAC for input prefetching. Configure
`spec.config.generated.prefetching` and a virtual build directory on the pool;
the worker operator reads the FSAC store from the Buildbarn chart's shared
`common.libsonnet`.

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
- The examples use a separate `emptyDir` CAS cache for each Pod. If you switch
  to `hostPath` cache storage, ensure two worker Pods on the same node never
  share a CAS read-cache path or blocks file.
- If both pools run on the same node type, size classes are nominal. That is fine for testing the ISCC path. Use different machine types when you want the classes to represent real resource differences.

## Driving It

Point a build at the size-class platform:

```text
--remote_default_exec_properties=pool=sizeclass
```

Cold-history behavior depends on the scheduler version; do not assume every
action starts on the largest class. PageRank implementations that probe missing
samples first try the smallest class without samples, with a timeout equal to
the smaller of the action's original timeout and `pageRank.minimumExecutionTimeout`.
Failed foreground probes fall back to the largest class. Losing ISCC history
therefore repeats exploration and fallback work instead of reusing learned choices.

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
