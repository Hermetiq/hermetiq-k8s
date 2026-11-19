# Buildbarn Storage Operations

This doc is the operator's view of the storage model in [buildbarn-storage-model.md](buildbarn-storage-model.md). Use it when planning restarts, upgrades, resizes, shard-count changes, or incident response.

The short version: Buildbarn storage is a cache, but it is still worth treating storage changes deliberately. Most mistakes are recoverable as cold builds. The expensive mistake is assuming a store is persistent when one of the persistence pieces is actually ephemeral.

## What Survives a Restart

A store survives a restart only when these three pieces survive together:

- the blocks, which hold blob bytes
- the key-location map, which says where each digest lives
- the `persistent_state` directory, which records valid blocks and the map hash seed

Lose any one of them and the store comes back empty. The data bytes may still be on disk, but Buildbarn cannot safely find them.

> **The metadata volume is not optional bookkeeping.** For raw block stores, the key-location map file and `persistent_state` directory live on the companion metadata volume. Deleting that small metadata volume empties the store just as surely as deleting the blocks device.

An in-memory key-location map means cache-only behavior. This is true even if the blocks sit on a durable Persistent Disk. After a pod restart, the bytes have no index and the store starts empty.

The chart defaults to `backend: filesystem` and `mode: pvc`. This table shows the
KLM default and storage-process restart behavior for each backend:

| Store | Enabled by default | Filesystem backend | Raw-block backend |
|---|---|---|---|
| CAS | yes | Disk-backed map; recovers | In-memory map; empty |
| CMS | yes, sharing CAS | Disk-backed map; recovers | Dedicated raw CMS: in-memory map; empty |
| AC | yes | In-memory map; empty | In-memory map; empty |
| ISCC | no | In-memory map; empty | In-memory map; empty |
| FSAC | no | In-memory map; empty | In-memory map; empty |

“Recovers” requires the same blocks, KLM, and state directory to remain available;
it does not make an ephemeral volume durable. Volume lifetime is a separate
choice: see the restart/reschedule table below. Explicit values overrides can
change these defaults. Losing AC forces actions to execute again, losing CAS
requires blob uploads/recomputation, losing ISCC repeats scheduling exploration,
and losing FSAC discards learned input-prefetch hints. Losing CMS makes composite
CAS blobs unreadable even when their chunks remain in CAS. The default
`cms.backend: sharedCas` puts CMS blocks, index, and state on the CAS filesystem
or raw CAS metadata volume. When raw CAS uses an in-memory index, that filesystem
is absent and shared CMS falls back to an in-memory store.

The chart's disk-backed KLM settings are:

- filesystem CAS: already disk-backed through `keyLocationMapSizeMi`
- shared-CAS CMS: already file-backed on the CAS filesystem or metadata volume; raw CAS with an in-memory index falls back to an in-memory CMS
- dedicated filesystem CMS: already disk-backed through `keyLocationMap.type: blockDevice`
- filesystem AC/ISCC/FSAC: opt in with `keyLocationMap.type: blockDevice`
- raw block stores: opt in with `blockDevice.keyLocationMap: file`

The [persistent profile](../custom-values/buildbarn-values-persistent.yaml) selects
these settings for CAS, CMS, AC, ISCC, and FSAC. The chart defaults remain
unchanged when the profile is omitted; adopting it is an explicit migration,
described below.

Explicit values take precedence over chart defaults; among values files, the
last file wins. The first conversion from an in-memory index starts empty and
cannot recover previously lost history. Later restarts can recover only when the
blocks, index, and state survive together. `storage.persistence.mode` applies to
all stores rather than to ISCC alone.

Barn Owl's `store_not_persistent` advisory identifies storage-tier stores whose
contents are discarded on restart, even if their blocks are on a durable
volume. Persistence requires both a disk-backed key-location map and the
generated Buildbarn `persistent` configuration with a durable state directory.
Use the chart settings above to opt in per store. Rebuilding a store after
restart can be intentional; changing its key-location map layout flushes it
once before subsequent restarts preserve its contents.

Persistent stores use a 300-second **minimum** interval between routine data syncs.
A crash can lose recent unsynchronized writes; five minutes is not a maximum
loss window because slow or failing syncs can delay persistence further. A clean
shutdown performs two full block-device syncs plus a state write. If that cannot
finish inside the pod grace period (30 seconds by default), recovery uses the
last persisted state. Increase `storage.terminationGracePeriodSeconds` when the
underlying disks need more time to flush.

| Configuration | Pod restart on same node | Rescheduled to another node | Backing disk/PV lost |
|---|---|---|---|
| `mode: pvc`, durable attachable PV, disk-backed KLM | survives | survives, subject to disk zone | empty |
| `mode: pvc`, node-local PV, disk-backed KLM | survives while the local disk remains | cannot reattach the local PV on another node | empty |
| `mode: pvc`, in-memory KLM | empty | empty | empty |
| `mode: emptyDir` | empty; container-only crashes may preserve disk-backed-KLM stores | empty | empty |
| `mode: hostPath`, in-memory KLM | empty | empty | empty |
| `mode: hostPath`, `blockDevice.keyLocationMap: file` on node-local metadata | survives | empty | empty |

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

Block geometry must match exactly for Buildbarn to reattach persistent data. Changing `spareBlocks`, `oldBlocks`, `currentBlocks`, `newBlocks`, `blocksSizeGi`, or the raw device size changes the derived block size. A persistent store discards all existing data on the next start.

Treat these as scheduled cache flushes:

| Change | Effect |
|---|---|
| Block counts, `blocksSizeGi`, or raw device size | Full flush of that store in persistent modes |
| Key-location map size or placement | Index starts empty; effectively a full flush |
| `storage.replicas` increased by 1 | Roughly `1/N` of keys remap to the new shard; temporary miss-rate dip |
| `storage.replicas` decreased by 1 | Removed shard's cache share is lost |
| `mode` or `backend` switch | New empty volumes; old PVCs may be retained and orphaned |
| Enabling `iscc`, `fsac`, or a dedicated `cms` (`filesystem`/`blockDevice`) on `mode: pvc` | Adds a StatefulSet claim template; requires a [StatefulSet recreate](#recreate-the-storage-statefulset) |
| Switching raw-block KLM from `inMemory` to `file` on `mode: pvc` | Adds a `<store>-meta` claim template; requires a [StatefulSet recreate](#recreate-the-storage-statefulset) and starts empty |

Volatile stores do not lose anything extra from these changes because they already restart empty.

## Monitoring

The most useful capacity signal is eviction age:

```text
time() - buildbarn_blobstore_old_current_new_location_blob_map_last_removed_old_block_insertion_time_seconds
```

The gauge holds the time at which the most recently discarded block entered the old range. Every blob in that block was written before then, so the value is a lower bound on how long the most recently discarded data survived. It is not a guarantee for any particular blob, and it keeps growing until the next block is discarded. bb-storage sets the gauge to the process start time on startup, so after a restart it reads as uptime until a block filled since the restart is discarded. Keep it comfortably above your longest build, plus any window where Bazel may still need remote outputs. A low value is a strong sign the store is too small; a high value alone does not prove it is big enough. The chart records per-shard min/max values and ships a `BuildbarnCacheRetentionLow` alert at 24 hours.

Watch the key-location map separately (CDC `bb-storage` exposes these under
`buildbarn_lossymap_hash_map_*` with `name="KeyLocationMap:<storage_type>"`;
the chart's recording rules preserve the legacy `buildbarn_blobstore_hashing_key_location_map_*`
rule names across mixed rollouts):

```text
buildbarn_lossymap_hash_map_put_too_many_iterations_total{name=~"KeyLocationMap:.+"}
buildbarn_lossymap_hash_map_get_too_many_attempts_total{name=~"KeyLocationMap:.+"}
```

Any sustained nonzero rate means the map is too small or too crowded. Grow the map. If it is in memory, grow the storage pod memory request at the same time. These counters reset on restart, so a quiet dashboard immediately after a deploy is not proof that the map is healthy.

| Symptom | Likely cause | Fix |
|---|---|---|
| `NotFound` mid-build for blobs that were just uploaded | Key-location map is saturated | Grow entries or `sizeMi`; increase memory request for in-memory maps |
| AC hits but actions still rerun | CAS evicted outputs before the AC evicted the ActionResult | Grow CAS, reduce AC retention, or expire the AC |
| Shard empty after node reboot | In-memory KLM or ephemeral storage tier | Expected for cache-only tiers; use disk-backed KLM if persistence is required |
| Disk was grown, but new blobs disappear early | KLM was not grown with the blocks | Resize blocks and map together |
| Writes fail with `No unused blocks available` | Reads are pinning old blocks and there are too few spare blocks | Raise `spareBlocks`; this is a geometry change and flushes persistent stores |

## Runbooks

### Migrate to Persistent Indexes

This procedure changes index placement within the CDC storage format. If you are
also upgrading from a pre-CDC image, follow the complete
[storage format cutover and rollback runbook](buildbarn-storage-model.md#storage-format-cutover-and-rollback)
instead. That upgrade requires a coordinated cold reset of CAS and any enabled
AC/ISCC/FSAC stores, including stores that were already persistent. Retaining
their old PVCs or adding this profile does not convert their contents. You can
apply the profile during that planned cutover after reviewing the capacity and
claim changes below.

Use [`custom-values/buildbarn-values-persistent.yaml`](../custom-values/buildbarn-values-persistent.yaml)
to opt into disk-backed indexes for CAS, CMS, AC, ISCC, and FSAC. The profile only
changes index types for both backends; it does not enable ISCC/FSAC or change
backends, volume mode, block geometry, index sizes, paths, StorageClasses, or
resources. CMS retains its configured backend, including the default `sharedCas`.
Existing installations that omit it keep the defaults of the chart version
they install. Within CDC, already-persistent stores keep their paths and sizes
when this profile is added.

1. **Capture the current configuration.** Save the current release values and
   rendered manifest, and retain your deployment values file. Check for
   `configOverrides` that replace the generated storage config. Do not combine
   this conversion with a shard-count, backend, block-size, or index-size change
   on an already-persistent store: those changes can invalidate its existing data.

2. **Check capacity for every enabled store.** A disk index uses 66 bytes per
   record, so `index MiB >= desired entries × 66 / 1048576`, rounded up. Continue
   sizing entries against blob capacity, not only the current working set.
   `keyLocationMap.entries` and `keyLocationMapInMemoryEntries` stop controlling
   capacity once the index moves to a file; review `keyLocationMap.sizeMi` or
   `blockDevice.metadata.keyLocationMapSizeMi` instead. The chart's sizing guard
   uses the same 66-byte disk-record size; the roughly 64-byte in-memory entry
   estimate does not size file indexes. Keep space for state and filesystem
   metadata. Include shared CMS in the CAS filesystem or metadata-volume budget:
   its defaults add 1Gi of
   blocks and a 256Mi index. For example, the default filesystem AC uses 10Gi blocks
   plus a 1344Mi index inside a 12Gi claim; a customized 11Gi blocks file would
   not fit. Budget page-cache memory and sync I/O too: the raw-CAS file default
   is 7360Mi, much larger than its default 24M-entry RAM map (~1.43GiB). The
   profile deliberately does not resize indexes or adjust resource limits.

3. **Prepare storage according to the existing backend.**

   | Existing store | Preparation and migration |
   |---|---|
   | Filesystem + PVC | Ensure the existing claim has room for the index and state at the paths listed below; no new claim is needed for an already-enabled store. Keep its blocks file and geometry unchanged. |
   | Filesystem + hostPath | Ensure free space in the existing `hostPath.path`; recovery remains limited to that retained node and filesystem. |
   | Filesystem + emptyDir | Ensure `emptyDir.sizeLimit` fits the blocks and index. Container restarts may recover, but replacing the pod still loses the store. |
   | Raw block + PVC | Set each store's `blockDevice.metadata.storageClassName` to a class that provisions Filesystem volumes and check `metadata.size`. New `<store>-meta` claim templates require the [StatefulSet recreate procedure](#recreate-the-storage-statefulset); retain the existing `<store>-blocks` claims. |
   | Raw block + hostPath | Supply a retained filesystem `blockDevice.metadata.hostPath.path` for every enabled store. This adds pod volumes, not PVC templates, so no StatefulSet recreation is needed. |

   CAS uses `cdc-v1/keys.db`; AC/ISCC/FSAC use
   `cdc-v1/<store>-keys.db`, with `cdc-v1/persistent_state/` alongside each map.
   Shared CMS uses `cdc-v1/cms-{blocks,keys}.db` and
   `cdc-v1/cms_persistent_state/` on the CAS filesystem or metadata volume; it
   needs no separate claim or hostPath. Dedicated CMS uses `cms-keys.db` and
   `persistent_state/` directly under `/storage-cms` or `/storage-cms-meta`, and
   requires the same capacity and metadata review as the other stores.

   For example, these overrides add metadata directories to an existing raw
   hostPath deployment. Choose mounted filesystems with sufficient capacity;
   these example paths deliberately use the GKE node boot filesystem. They assume
   the default `cms.backend: sharedCas`; a dedicated raw CMS needs its own
   `cms.blockDevice.metadata.hostPath.path` too:

   ```yaml
   storage:
     persistence:
       cas:
         blockDevice:
           metadata:
             hostPath: { path: /mnt/stateful_partition/buildbarn-storage/cas-meta }
       ac:
         blockDevice:
           metadata:
             hostPath: { path: /mnt/stateful_partition/buildbarn-storage/ac-meta }
       iscc:
         blockDevice:
           metadata:
             hostPath: { path: /mnt/stateful_partition/buildbarn-storage/iscc-meta }
       fsac:
         blockDevice:
           metadata:
             hostPath: { path: /mnt/stateful_partition/buildbarn-storage/fsac-meta }
   ```

   `metadata.size` provisions a PVC only in PVC mode; it does not reserve or
   enforce hostPath space. Node-local metadata cannot protect lost Local SSD
   blocks. Surviving node replacement requires durable storage for both. Enabling
   previously disabled ISCC/FSAC, or switching shared CMS to a dedicated volume,
   is a separate change and can add PVC templates.

4. **Render and inspect before upgrading.** From the repository root, apply the
   profile after deployment values, and any reviewed sizing/path overrides last:

   ```bash
   helm template buildbarn ./charts/buildbarn --namespace hermetiq \
     -f deployment-values.yaml \
     -f custom-values/buildbarn-values-persistent.yaml \
     -f persistence-overrides.yaml > buildbarn-persistent-rendered.yaml
   helm lint ./charts/buildbarn \
     -f deployment-values.yaml \
     -f custom-values/buildbarn-values-persistent.yaml \
     -f persistence-overrides.yaml
   ```

   Use an empty `persistence-overrides.yaml` or omit that argument if no overrides
   are needed. Compare with the saved manifest: check file-index paths,
   `persistent.stateDirectoryPath`, volume mounts, init permissions, and expected
   claim additions. Verify block sizes, device paths, shard count, and unrelated
   settings are unchanged. A later `inMemory` override intentionally opts that
   store back out.

5. **Perform the reviewed migration.** Schedule a cold-cache window, because
   each previously volatile store starts empty on the first conversion. Drain
   builds first; if CAS or CMS is reset, restart frontends before resuming clients
   so stale positive existence-cache entries cannot hide missing blobs. For raw
   PVC stores, follow the StatefulSet recreate procedure before expecting the
   upgrade to succeed. Otherwise, use a normal upgrade with the same file order:

   ```bash
   helm upgrade buildbarn ./charts/buildbarn --namespace hermetiq \
     -f deployment-values.yaml \
     -f custom-values/buildbarn-values-persistent.yaml \
     -f persistence-overrides.yaml
   ```

   Retain the profile in subsequent upgrades; omitting it can restore volatile
   defaults. Confirm healthy storage pods and successful metadata mounts, then
   verify retained history/cache entries through a controlled graceful restart
   after the store has warmed and persisted state. Allow enough termination
   grace time for the disks to sync. Abrupt failures can still lose unsynchronized
   writes as described above.

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

Kubernetes rejects changes to a StatefulSet's `volumeClaimTemplates`. Enabling
ISCC/FSAC or a dedicated CMS on `mode: pvc`, adding raw-block metadata claims,
switching a store's backend, or changing a claim size can therefore require this
procedure. Keep the existing PVCs and pods; replace only the StatefulSet object
before the rollout.

For a pre-CDC upgrade, use the
[storage format cutover](buildbarn-storage-model.md#storage-format-cutover-and-rollback)
to stop all writers and storage first. The orphaned, running-pod procedure below
is for changes within the same storage format; it does not make mixed pre-CDC and
CDC storage safe.

1. Render and lint the intended chart and values, then compare with the current
   release manifest. Confirm the claim-template changes are intentional and that
   existing claim names and data geometry are preserved where required. Do not
   use an intentionally failing real upgrade as the preflight: Helm can update
   ConfigMaps or other resources before the StatefulSet update fails. During the
   planned migration window, delete the StatefulSet while leaving its pods and
   PVCs running:

   ```bash
   kubectl delete statefulset storage --namespace hermetiq --cascade=orphan
   ```

2. Run the reviewed `helm upgrade` with the complete values-file list, including
   the persistent profile and any sizing/path overrides. The recreated
   StatefulSet adopts the orphaned `storage-N` pods. Coordinate this operation
   with any GitOps controller so it does not restore the old configuration.

3. Monitor the StatefulSet's rolling update. New metadata/store claims are
   provisioned as pods are recreated; existing claims are reused unchanged:

   ```bash
   kubectl rollout status statefulset storage --namespace hermetiq
   kubectl get pvc --namespace hermetiq
   ```

   If the recreated StatefulSet has not rolled its existing pods onto the new
   template, trigger `kubectl rollout restart statefulset storage --namespace hermetiq`
   and monitor it again. Confirm storage health and metadata mounts before
   resuming builds.

4. If the change created new volumes for an existing store (a `backend` or `size` change without in-place expansion), the previous claims are now orphaned. Delete them deliberately once the cache is warming so they stop billing.

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
