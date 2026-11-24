# Buildbarn Storage Operations

This doc is the operator's view of the storage model in [buildbarn-storage-model.md](buildbarn-storage-model.md). Use it when planning restarts, upgrades, resizes, shard-count changes, or incident response.

The short version: Buildbarn storage is a cache, but it is still worth treating storage changes deliberately. Most mistakes are recoverable as cold builds. The expensive mistake is assuming a store is persistent when one of the persistence pieces is actually ephemeral.

## What Survives a Restart

A store survives a restart only when these three pieces survive together:

- the blocks, which hold blob bytes
- the key-location map, which says where each digest lives
- the `persistent_state` directory, which records valid blocks and the map hash seed

Treat these as one consistency unit. Losing the index/state makes old data
unreachable. Losing or replacing the blocks while retaining index/state can
instead produce **false presence**: `FindMissingBlobs` reports a blob present,
but reading it fails. The pinned storage implementation reattaches blocks by
location; it does not verify all contents on startup. Stop the shard and reset
both sides before serving requests after disk replacement.

For Local SSD, put metadata on the same SSD storage and enforce a paired reset
lifecycle. Never use boot-disk or network metadata over disposable local blocks.
With raw PVCs, deleting/recreating `<store>-blocks` requires resetting/deleting
`<store>-meta` too; shared CMS belongs to the CAS metadata volume. Retain rollback
snapshots only as consistent blocks+metadata pairs taken while storage is stopped.

> **The metadata volume is not optional bookkeeping.** For raw block stores, the key-location map file and `persistent_state` directory live on the companion metadata volume. Deleting metadata discards access to old data; deleting blocks alone can leave false index hits. Always reset or restore them as a matching pair.

An in-memory key-location map means cache-only behavior. This is true even if the blocks sit on a durable Persistent Disk. After a pod restart, the bytes have no index and the store starts empty.

The chart defaults to `backend: filesystem`, `mode: pvc`, and persistent indexes
for all five stores, with ISCC and FSAC enabled. Scheduler size-class analysis
and worker prefetching remain separate opt-ins. Set an unused ISCC or FSAC store's
`enabled` flag to `false` to omit it.
These defaults apply to both PVC storage and raw blocks on local NVMe:

| Store | Enabled by default | Filesystem backend | Raw-block backend |
|---|---|---|---|
| CAS | yes | Disk-backed map; recovers | Disk-backed map; recovers |
| CMS | yes, sharing CAS | Disk-backed map; recovers | Shared CAS metadata or dedicated raw CMS; recovers |
| AC | yes | Disk-backed map; recovers | Disk-backed map; recovers |
| ISCC | yes | Disk-backed map; recovers | Disk-backed map; recovers |
| FSAC | yes | Disk-backed map; recovers | Disk-backed map; recovers |

“Recovers” requires the same blocks, KLM, and state directory to remain available;
it does not make an ephemeral volume durable. Volume lifetime is a separate
choice: see the restart/reschedule table below. Explicit values overrides can
change these defaults. Losing AC forces actions to execute again, losing CAS
requires blob uploads/recomputation, losing ISCC repeats scheduling exploration,
and losing FSAC discards learned input-prefetch hints. Losing CMS makes composite
CAS blobs unreadable even when their chunks remain in CAS: with the default
chunking parameters that is every blob of 512 KiB or more. The default
`cms.backend: sharedCas` puts CMS blocks, index, and state on the CAS filesystem
or raw CAS metadata volume. When raw CAS uses an in-memory index, that filesystem
is absent and shared CMS falls back to an in-memory store.

The chart's disk-backed KLM settings are:

- filesystem CAS: already disk-backed through `keyLocationMapSizeMi`
- shared-CAS CMS: already file-backed on the CAS filesystem or metadata volume; raw CAS with an in-memory index falls back to an in-memory CMS
- dedicated filesystem CMS: already disk-backed through `keyLocationMap.type: blockDevice`
- filesystem AC/ISCC/FSAC: `keyLocationMap.type: blockDevice` by default
- raw block stores: `blockDevice.keyLocationMap: file` by default

The [persistent profile](../custom-values/buildbarn-values-persistent.yaml)
explicitly selects these same defaults. It is useful after deployment values
that set `inMemory`; a deployment on chart defaults does not need it. Raw
hostPath stores must supply metadata directories that already exist on the
node (their hostPath `type` defaults to `Directory`), and each raw PVC store
has a `<store>-meta` claim template. At default filesystem sizes, the ISCC and
FSAC claims add 2Gi and 6Gi per storage replica, on StorageClass `premium-rwo`
whatever class CAS and AC use: every store has its own `storageClassName`.
Set an unused store's `enabled` flag to `false`. In `emptyDir` mode the two
stores each need an `emptyDir.sizeLimit`, and in `hostPath` mode they need
their own paths when CAS does not use the chart default path; the render fails
otherwise.

Explicit values take precedence over chart defaults; among values files, the
last file wins. The first conversion from an in-memory index starts empty and
cannot recover previously lost history. Later restarts can recover only when the
blocks, index, and state survive together. `storage.persistence.mode` applies to
all stores rather than to ISCC alone.

Barn Owl's `store_not_persistent` advisory identifies storage-tier stores whose
contents are discarded on restart, even if their blocks are on a durable
volume. Persistence requires both a disk-backed key-location map and the
generated Buildbarn `persistent` configuration with a durable state directory.
Check explicit index overrides when this advisory appears. Rebuilding a store after
restart can be intentional; changing its key-location map layout flushes it
once before subsequent restarts preserve its contents.

Persistent stores use a 300-second **minimum** interval between routine data syncs.
A crash can lose recent unsynchronized writes; five minutes is not a maximum
loss window because slow or failing syncs can delay persistence further. A clean
shutdown performs two full block-device syncs plus a state write. If that cannot
finish inside the pod grace period, recovery uses the last persisted state.
The chart sets `storage.terminationGracePeriodSeconds: 120`; setting it to
`null` restores Kubernetes' 30-second default. Increase it further when the
underlying disks need more time to flush.

| Configuration | Pod restart on same node | Rescheduled to another node | Backing disk/PV lost |
|---|---|---|---|
| `mode: pvc`, durable attachable PV, disk-backed KLM | survives | survives, subject to disk zone | reset paired blocks and metadata before serving |
| `mode: pvc`, node-local PV, disk-backed KLM | survives while the local disk remains | cannot reattach the local PV on another node | reset paired blocks and metadata before serving |
| `mode: pvc`, in-memory KLM | empty | empty | empty |
| `mode: emptyDir` | empty; container-only crashes may preserve disk-backed-KLM stores | empty | empty |
| `mode: hostPath`, in-memory KLM | empty | empty | empty |
| `mode: hostPath`, file index on same local storage with verified paired lifecycle | survives while both remain | requires a new empty pair | reset both; stale metadata can report false hits |

For durable network-backed PVCs, a node loss is normally a reschedule: the disk
reattaches where Kubernetes can run the pod. A PVC backed by local storage, such
as TopoLVM on Local SSD, remains tied to its node. PVC plumbing alone does not
protect against node or disk loss.

The frontend's optional read cache always has an in-memory index and starts empty
after a frontend process restart, even when its blocks use hostPath. The frontend
existence cache (enabled by default, 300-second TTL) also resets on frontend
restart, but survives a storage-only restart: if volatile CAS disappears, it can
temporarily tell clients that missing blobs still exist.

## Changes That Flush the Cache

Treat changes to block counts, `blocksSizeGi`, raw device size or index layout
as potentially cache-invalidating and plan for a cold cache. Buildbarn must
reattach the same block offsets and sizes to recover persistent data. Changing
the total block count or backing size normally changes that geometry.

Redistributing `oldBlocks` and `currentBlocks` while keeping the total count,
spare count and physical geometry unchanged can retain persisted data, but
unchanged totals alone are not a preservation guarantee. The backing storage,
disk-backed key-location map and checkpoint state must also remain compatible
and survive together. This is restart recovery, not online resizing, and the
new retention policy can still evict data. Unless those conditions are
verified for the deployed version and layout, keep the cold-cache plan.

Treat these as scheduled cache flushes:

| Change | Effect |
|---|---|
| Block counts, `blocksSizeGi`, or raw device size | Plan for a full flush; changed physical geometry prevents reattachment. See the restricted redistribution case above before claiming preservation |
| Key-location map size or placement | Index starts empty; effectively a full flush |
| CMS index size (`cms.keyLocationMap.sizeMi`, or `cms.blockDevice.metadata.keyLocationMapSizeMi` for a dedicated raw CMS), including a changed chart default taken on upgrade | The CMS starts empty. The chunks stay in CAS, but every blob of 512 KiB or more (two or more chunks at the default chunking parameters) is unreadable and reported missing until it is uploaded again |
| `storage.replicas` increased by 1 | Roughly `1/N` of keys remap to the new shard; temporary miss-rate dip |
| `storage.replicas` decreased by 1 | Removed shard's cache share is lost |
| `mode` or `backend` switch | New empty volumes; old PVCs may be retained and orphaned |
| Enabling or disabling `iscc`, `fsac`, or a dedicated `cms` (`filesystem`/`blockDevice`) on `mode: pvc` | Adds or removes a StatefulSet claim template; requires a [StatefulSet recreate](#recreate-the-storage-statefulset) |
| Switching raw-block KLM from `inMemory` to `file` on `mode: pvc` | Adds a `<store>-meta` claim template; requires a [StatefulSet recreate](#recreate-the-storage-statefulset) and starts empty |

Volatile stores do not lose anything extra from these changes because they already restart empty.

## Monitoring

The most useful capacity signal is eviction age:

```text
time() - buildbarn_blobstore_old_current_new_location_blob_map_last_removed_old_block_insertion_time_seconds
```

The gauge holds the time at which the most recently discarded block entered the old range. Every blob in that block was written before then, so the value is a lower bound on how long the most recently discarded data survived. It is not a guarantee for any particular blob, and it keeps growing until the next block is discarded. bb-storage sets the gauge to the process start time on startup, so after a restart it reads as uptime until a block filled since the restart is discarded. Keep it comfortably above your longest build, plus any window where Bazel may still need remote outputs. A low value is a strong sign the store is too small; a high value alone does not prove it is big enough. The chart records per-shard min/max values and ships a `BuildbarnCacheRetentionLow` alert at 24 hours.

Watch the key-location map separately (`bb-storage` exposes these under
`buildbarn_lossymap_hash_map_*` with `name="KeyLocationMap:<storage_type>"`;
the chart's recording rules publish them under
`buildbarn_blobstore_hashing_key_location_map_*` rule names):

```text
buildbarn_lossymap_hash_map_put_too_many_iterations_total{kubernetes_service="storage",name=~"KeyLocationMap:.+"}
buildbarn_lossymap_hash_map_get_too_many_attempts_total{kubernetes_service="storage",name=~"KeyLocationMap:.+"}
```

Any sustained nonzero rate means the map is too small or too crowded. Grow the map. If it is in memory, grow the storage pod memory request at the same time. These counters reset on restart, so a quiet dashboard immediately after a deploy is not proof that the map is healthy.

The chart's six key-location-map recording rules and the two alerts built on
them, `BuildbarnKeyLocationMapPutsDropped` and
`BuildbarnKeyLocationMapGetsExhausted`, select `kubernetes_service="storage"`
only. Worker local read caches and the optional frontend read cache keep their
own key-location maps and report them under the same `name`
(`KeyLocationMap:cs`). They are not in the recorded series, in the `bb-storage`
dashboard's key-location-map panels, which read those series, or in these
alerts. To watch one, query the raw `buildbarn_lossymap_hash_map_*` metrics with
`kubernetes_service` set to `frontend` or to the RbeWorker's name.

The storage scope depends on the `kubernetes_service` pod label reaching the
series. The chart's VMPodScrapes copy it (`podTargetLabels`). With
`vmPodScrapes.enabled=false` and your own scrape configuration, copy that pod
label too, or the six records are empty and both alerts stay silent.

| Symptom | Likely cause | Fix |
|---|---|---|
| `NotFound` mid-build for blobs that were just uploaded | Key-location map is saturated | Grow entries or `sizeMi`; increase memory request for in-memory maps |
| AC hits but actions still rerun | CAS evicted outputs before the AC evicted the ActionResult | Grow CAS, reduce AC retention, or expire the AC |
| Shard empty after node reboot | In-memory KLM or ephemeral storage tier | Expected for cache-only tiers; use disk-backed KLM if persistence is required |
| Disk was grown, but new blobs disappear early | KLM was not grown with the blocks | Resize blocks and map together |
| Writes fail with `No unused blocks available` | Reads are pinning old blocks and there are too few spare blocks | Review `spareBlocks`; increasing the total block count changes geometry, so plan the change as a cache flush |

## Runbooks

### Preview a Storage Change

<a name="migrate-to-persistent-indexes"></a>

Render and inspect a storage change before applying it. From the repository
root, pass your values files in the order you deploy them:

```bash
helm template buildbarn ./charts/buildbarn --namespace hermetiq \
  -f deployment-values.yaml \
  --set storage.keyLocationMapSizing.validate=true > buildbarn-rendered.yaml
```

Compare the result with the manifest of the running release
(`helm get manifest buildbarn --namespace hermetiq`): check file-index paths,
`persistent.stateDirectoryPath`, volume mounts, init permissions, and expected
claim additions. Verify block sizes, device paths, shard count, and unrelated
settings are unchanged.

`helm template` runs the chart's render guards, but it prints no NOTES and
cannot see the cluster. `storage.keyLocationMapSizing.validate=true` makes
an undersized index a render error that shows the arithmetic; with the
default `false` the same finding is only a `WARNING: STORAGE INDEX CAPACITY`
line in NOTES. Keep the setting in your values once the render passes.
`helm lint` is not a substitute for the render: it logs the chart's `fail`
guards as informational messages and still reports the chart as passing.

Then run the upgrade command you intend to use, with the same values files
and flags, as a server-side dry run against the cluster:

```bash
helm upgrade buildbarn ./charts/buildbarn --namespace hermetiq --dry-run=server \
  -f deployment-values.yaml
```

It applies nothing. It runs the `lookup` checks an offline render skips: live
`RbeWorker` and worker ConfigMap contents, and the comparison of the live
`storage` StatefulSet's claim templates with the rendered ones (see
[Recreate the Storage StatefulSet](#recreate-the-storage-statefulset)). It
also prints NOTES at the end of its output. Read the storage lines there:
`WARNING: VOLATILE STORAGE STORES`, `WARNING: STORAGE INDEX CAPACITY`,
`WARNING: STORAGE CLASS MISMATCH`, and the `emptyDir` warning. A bare
`--dry-run` is a client-side render and skips the same checks. A GitOps
tool that renders with `helm template` runs neither the lookup checks nor
NOTES.

Moving a store from an in-memory index to a file index is such a change: the
store starts empty on the first conversion, and a raw PVC store gains a
`<store>-meta` claim template.

### Explicit Ephemeral Opt-Out

Apply [`custom-values/buildbarn-values-ephemeral.yaml`](../custom-values/buildbarn-values-ephemeral.yaml)
**after** deployment values when losing indexes on restart is intentional:

```bash
helm template buildbarn ./charts/buildbarn --namespace hermetiq \
  -f deployment-values.yaml \
  -f custom-values/buildbarn-values-ephemeral.yaml
```

The overlay selects in-memory indexes for every raw-block store and filesystem
CMS/AC/ISCC/FSAC. It leaves optional-store enablement, volume mode, backends,
geometry, sizes, and resources unchanged. Shared CMS becomes wholly in-memory
when raw CAS has no metadata filesystem. Raw stores then need no metadata
volumes; changing an existing PVC release to this layout removes its
`<store>-meta` claim templates, which are immutable, so follow
[Recreate the Storage StatefulSet](#recreate-the-storage-statefulset). For a
cold discard, stop storage and reset/delete both the blocks and metadata claims
before creating the volatile store. If rollback is needed, first take a consistent
snapshot/copy of both while stopped; retained metadata alone is not a rollback
point after its blocks have been modified. Returning to persistent indexes starts
cold; never reattach a stale checkpoint over blocks written in volatile mode.

The overlay carries no RAM entry counts. A raw store switched to a RAM index is
sized by `storage.persistence.<store>.blockDevice.keyLocationMapInMemoryEntries`,
and the chart defaults fit the default device sizes only: 24,000,000 entries
for the 200Gi raw CAS. Set it explicitly for any larger device:

```text
usable bytes = device bytes × (oldBlocks + currentBlocks + newBlocks)
                            / (oldBlocks + currentBlocks + newBlocks + spareBlocks)
entries     >= 2 × usable bytes / mean object size
```

Mean object size is `storage.keyLocationMapSizing.averageObjectSizeBytes.<store>`
and `2` is `storage.keyLocationMapSizing.minimumRatio`. A 1000Gi raw CAS at the
default 17,408 bytes needs at least 114,950,845 entries. Budget about 64 bytes
of storage-pod memory per entry. With `storage.keyLocationMapSizing.validate=true`
an undersized RAM index fails the render and the error states the required
count. With the guard off, which is the chart default, the same values render
and deploy silently; the only sign is a `WARNING: STORAGE INDEX CAPACITY` line
in NOTES, which `helm template` does not print. Filesystem CMS/AC/ISCC/FSAC
switched to RAM are sized by `keyLocationMap.entries` under the same rule.

The Local SSD overlay
([`custom-values/buildbarn-values-local-ssd-block.yaml`](../custom-values/buildbarn-values-local-ssd-block.yaml))
enables the guard and carries
`storage.persistence.cas.blockDevice.keyLocationMapInMemoryEntries: 83000000`
for its 718Gi CAS. The value is unused while the index is file-backed; it is
there so that applying the ephemeral overlay after that overlay renders.
83,000,000 entries are about 5GiB of memory: review the storage memory request
before deploying that combination.

Filesystem CAS always uses a file-backed index in this chart. To make that store
pod-lifetime as well, explicitly select `storage.persistence.mode: emptyDir` and
set `emptyDir.sizeLimit` for every enabled filesystem store. Changing volume mode
is a separate change and must not be used to discard an existing release's
PVCs accidentally. File-backed indexes on `emptyDir` can survive container-only
restarts, but not pod replacement.

The ephemeral overlay is not a speed recommendation. RAM maps avoid file writes
but consume Go heap; disk maps use the OS page cache for hot lookups. Budget for
either choice, and expect the opt-out to discard AC hits, ISCC learning, FSAC
hints, and raw CAS/CMS contents on storage-process restart. Frontend read caches
remain intentionally volatile in both configurations.

### Resize a Store

Plan the resize as a cache flush. Resize the key-location map in the same change, because block capacity and map capacity are coupled. For PVC-backed storage, confirm the StorageClass has `allowVolumeExpansion: true` and expand each existing PVC first so its data is kept; the StatefulSet's `volumeClaimTemplates` still have to be updated to match, which needs the [Recreate the Storage StatefulSet](#recreate-the-storage-statefulset) steps. Without expansion, plan to recreate the StatefulSet and claims.

After the change:

- retention starts near zero and climbs as real builds refill the cache
- KLM dropped-put and exhausted-get alerts stay quiet
- storage pod memory is still within request if the map is in memory

### Scale Storage Shards

Change `storage.replicas` and run `helm upgrade`. The chart regenerates the rendezvous-hash shard map. Adding one shard remaps only the share that now belongs to that shard; it should look like a temporary miss-rate dip, not a full cache loss.

> **Be careful with `configOverrides`.** If you override `common.libsonnet`, the shard map inside that override is used verbatim. It is no longer derived from `storage.replicas`. Update the override in lockstep, or new pods may receive no traffic and removed pods may still be referenced. The chart prints an install-time warning when this override is present.

### Switch Storage Backend or Mode

Switching from filesystem to raw block, PVC to hostPath, or one backend to another creates new empty storage. StatefulSet `volumeClaimTemplates` are immutable, so the switch needs a [StatefulSet recreate](#recreate-the-storage-statefulset), and old PVCs are retained by default. After the new storage pods are healthy and the cache is warming, delete the old orphaned claims deliberately so they stop billing.

There is no built-in data migration between filesystem and raw block stores.

### Recreate the Storage StatefulSet

An upgrade from a chart older than 1.0.0 does not use this runbook: it
replaces the storage format, and
[Migrating the Buildbarn chart to 1.0.0](migrate-to-1.0.0-buildbarn.md) owns
that whole sequence.

Kubernetes rejects changes to a StatefulSet's `volumeClaimTemplates`. Enabling
or disabling ISCC/FSAC or a dedicated CMS on `mode: pvc`, adding raw-block
metadata claims, switching a store's backend, or changing a claim's size or
class therefore needs the StatefulSet object deleted and created again. The
PVCs are kept. Helm does not recreate the object for you. It patches every other
object of the release, the StatefulSet patch is then refused, and the release
is left failed and half-applied.

The chart refuses such a release before anything is applied. On a
`helm install` or `helm upgrade` against the cluster it looks up the live
StatefulSet named `storage` in the release namespace and fails when its claim
templates differ from the rendered ones. For a release that ran without ISCC
and FSAC and now enables both, the error is:

```text
live StatefulSet hermetiq/storage has different volumeClaimTemplates than this release renders: claim template "fsac" is added; claim template "iscc" is added. Kubernetes forbids changing volumeClaimTemplates in place, and Helm applies every other object of the release before that patch is refused, which leaves the release half-applied on the old StatefulSet. Stop storage first (scale statefulset/storage to 0 and wait for its pods to terminate), run `kubectl delete statefulset storage --namespace hermetiq --cascade=orphan`, then run this upgrade again so the StatefulSet is recreated with the rendered templates. Existing PersistentVolumeClaims are kept as they are: a changed class or size only applies to claims that do not exist yet. The same recreation is needed when rolling back to a revision whose claim templates differ; helm rollback does not run this check. Set upgradeChecks.skipStorageClaimTemplateCheck=true to skip it. See https://github.com/Hermetiq/hermetiq-k8s/blob/main/docs/buildbarn-storage-operations.md#recreate-the-storage-statefulset
```

The check compares claim names and their order, `storageClassName`,
`volumeMode`, and requested size. It needs `lookup`, so it runs on a real
install or upgrade and on `helm upgrade --dry-run=server`. It does not run for
`helm template`, a client-side dry run, a GitOps tool that renders with
`helm template`, or `helm rollback`; there the half-applied failure is still
what happens, so delete the StatefulSet as described below before syncing or
rolling back. With no live StatefulSet
there is nothing to compare, which is why the same upgrade passes once the
object has been deleted. `upgradeChecks.skipStorageClaimTemplateCheck=true`
turns the check off. Leave it `false`: skipping it does not make the change
possible, it only brings the half-applied failure back.

**Existing claims are reused by name.** A recreated StatefulSet looks for
`<template>-storage-<ordinal>` (`cas-storage-0`, `cas-meta-storage-0`,
`iscc-storage-1`) and creates only the claims that do not exist. A class or
size changed in values therefore reaches new claims only. An existing claim
keeps the class and size it was created with, and the chart's size checks read
the values, not the live claim. bb-storage creates its files sparse, so a live
claim that is too small starts normally and runs out of space as the store
fills. Run `kubectl get pvc --namespace hermetiq` before and after the change
and compare it with the rendered templates.

- To grow a claim, expand the PVC itself (raise its
  `spec.resources.requests.storage`, on a StorageClass with
  `allowVolumeExpansion: true`) and confirm the new capacity before starting
  storage. The template still has to be changed to match.
- To change a claim's class, delete that claim while storage is stopped and
  let the recreated StatefulSet create it again; a claim's StorageClass cannot
  be edited. Deleting a claim discards what it holds. For a filesystem store
  that is the whole store on that shard. For a raw store's `<store>-meta` claim
  it is the index and state, which resets the store on that shard, and with
  `cas-meta` the shared CMS: fresh metadata over old blocks is an empty store.
  Delete the `<store>-blocks` claim in the same step when the blocks move to
  another class too. Never keep a `<store>-meta` claim over a deleted or
  recreated `<store>-blocks` claim.

Which procedure applies depends on whether the set of claim names changes:

| Change | Procedure |
|---|---|
| A claim name is added or removed: ISCC, FSAC, or a dedicated CMS enabled or disabled; raw `<store>-meta` claims added or dropped; a backend or mode switch | Stopped recreation. If storage cannot be stopped, running recreation followed by deleting the pods by hand |
| The names stay the same and a class changes | Stopped recreation, deleting the affected claims in its step 4. A running recreation only brings the template in line and leaves every existing claim on its old class |
| The names stay the same and only a requested size changes | Running recreation, after expanding the existing PVCs |

**Stopped recreation.** Use this whenever a claim name is added or removed, or
a claim has to be deleted to change its class.

1. Render the intended chart and values and run the server-side dry run from
   [Preview a Storage Change](#preview-a-storage-change).
   While the old StatefulSet exists the dry run fails with the error above,
   which lists every claim-template difference. Confirm each one is intended
   and that claim names and data geometry are preserved where required. Do not
   use a real upgrade with the check skipped as the preflight.

2. Drain builds. Scale storage to zero and wait until the second command lists
   no pod, so that persistent stores write their final checkpoint:

   ```bash
   kubectl scale statefulset storage --namespace hermetiq --replicas=0
   kubectl get pods --namespace hermetiq --selector app=storage
   ```

   Every cache request fails while storage is down.

3. Delete the StatefulSet object. Its PVCs stay:

   ```bash
   kubectl delete statefulset storage --namespace hermetiq --cascade=orphan
   ```

4. Change existing claims now if the change calls for it: expand a claim that
   must grow, or delete a claim whose class must change, as described above.

5. Run the reviewed `helm upgrade` with the complete values-file list, including
   any sizing or path overrides. Helm creates the
   StatefulSet from the rendered templates with `storage.replicas` replicas. Its
   pods start from `storage-0` upward; each gets new claims for the templates
   that have none yet and reuses the rest. Coordinate this operation with any
   GitOps controller so it does not restore the old configuration in between.

6. Watch the pods come up and check the claims:

   ```bash
   kubectl rollout status statefulset storage --namespace hermetiq
   kubectl get pvc --namespace hermetiq
   ```

   Confirm that every claim has the intended class and capacity, and confirm
   storage health and metadata mounts before resuming builds. If the change
   reset CAS or CMS on any shard, restart frontends first so stale positive
   existence-cache entries cannot hide missing blobs.

**Running recreation.** Use this only when the claim names stay the same and
only requested sizes change. The storage pods keep running and keep their
existing claims.

1. Run the same preflight as step 1 above. Expand the existing PVCs first; see
   [Resize a Store](#resize-a-store).

2. Delete the StatefulSet while leaving its pods and PVCs running:

   ```bash
   kubectl delete statefulset storage --namespace hermetiq --cascade=orphan
   ```

3. Run the reviewed `helm upgrade` with the complete values-file list. The
   recreated StatefulSet adopts the orphaned `storage-N` pods.

4. Monitor the StatefulSet:

   ```bash
   kubectl rollout status statefulset storage --namespace hermetiq
   kubectl get pvc --namespace hermetiq
   ```

   The controller replaces the adopted pods only when the pod template changed
   as well. If they must restart on the new release and were not replaced,
   trigger `kubectl rollout restart statefulset storage --namespace hermetiq`
   and monitor it again.

**Running recreation with an added claim name.** The steps above do not finish
when the new StatefulSet has a claim template the adopted pods lack. The
StatefulSet controller tries to add the new volume to each running pod, the API
server refuses because a pod's volumes cannot be changed, and the controller
stops there, before it reaches its rolling update. Helm creates the StatefulSet
without error, `kubectl rollout status` hangs, the pods keep the old template
and image, and
`kubectl describe statefulset storage --namespace hermetiq` shows `FailedUpdate`
events. `kubectl rollout restart` does not help: it only changes the template,
and the controller fails at the same point first. A StatefulSet that only lost
claim names does not hit this, because every remaining template still has its
volume in the adopted pods, and the controller replaces those pods itself.

Either scale to zero before deleting the StatefulSet, as in the stopped
recreation, or delete the storage pods by hand after the upgrade. Go one at a
time from `storage-0` upward and wait for each replacement to be Ready before
deleting the next; the controller does not go past a pod it cannot reconcile,
so `storage-1` is not touched until `storage-0` has been replaced:

```bash
kubectl delete pod storage-0 --namespace hermetiq
kubectl get pods --namespace hermetiq --selector app=storage --watch
```

Each replacement is created from the new template with its new claims. Its
shard is unavailable while it restarts, and one unavailable shard fails
`FindMissingBlobs` for the whole cluster, so drain builds for this as well.

**Rollback.** `helm rollback` to a revision whose claim templates differ needs
the same recreation, and the chart cannot warn about it: a rollback applies the
stored manifest of the old revision and runs none of the chart's checks. Stop
storage and delete the StatefulSet first, then roll back. A rollback to a
chart older than 1.0.0 also crosses the storage format; follow the rollback
steps of the
[migration guide](migrate-to-1.0.0-buildbarn.md#storage-format-cutover-and-rollback).

**Cleanup.** If the change created replacement volumes, dispose of orphaned
raw blocks and their matching metadata claims together after the rollback
retention period. Keep consistent stopped snapshots if rollback is needed; never
mix an old metadata claim with a new or subsequently modified blocks claim.

### Invalidate Poisoned Action Results

If you need to force rebuilds without flushing the CAS, enable the chart's native `config.actionCache.actionResultExpiring` wrapper and set `minimumTimestamp` to the current UTC timestamp (a `configOverrides["common.libsonnet"]` override would also work, but it replaces the whole templated file, shard map and TLS blocks included, and the chart refuses it when `security.grpcMtls` is on):

```yaml
config:
  actionCache:
    actionResultExpiring:
      enabled: true
      minimumValidity: 2592000s      # 30d
      maximumValidityJitter: 259200s # 3d — MUST be nonzero; bb-storage divides by it
      minimumTimestamp: "2026-11-06T00:00:00Z" # hide ActionResults completed before this timestamp
```

Older ActionResults are hidden at read time. Set both `minimumValidity` and a nonzero `maximumValidityJitter`: an explicit `'0s'` jitter panics on the first AC hit, and an unset jitter fails startup (both are rejected by `templates/validate.yaml`).

For volatile deployments, restarting storage pods is simpler: it flushes AC and CAS together. On large persistent shards, give `storage.terminationGracePeriodSeconds` enough headroom for a clean flush during rolling restarts; see [What Survives a Restart](#what-survives-a-restart).

The cache is disposable by design. Every runbook above trades a temporary cold-build window for correctness. The durable part is the decision process: know whether each store is persistent, resize map and blocks together, and treat geometry changes as planned flushes.
