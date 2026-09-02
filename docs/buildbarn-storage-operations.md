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

To opt into persistence:

- filesystem CAS: already disk-backed through `keyLocationMapSizeMi`
- other filesystem stores: set `keyLocationMap.type: blockDevice`
- raw block stores: set `blockDevice.keyLocationMap: file`

Persistent stores sync state at most every 5 minutes. A crash can lose the newest few minutes of writes, which show up as normal cache misses and are re-uploaded. A clean shutdown performs two full block-device syncs plus a state write. If a large network-attached disk cannot finish inside the pod grace period, shutdown falls back to the crash behavior. That is usually harmless, but raise `storage.terminationGracePeriodSeconds` if clean flushes matter for your deployment.

| Configuration | Pod restart on same node | Rescheduled to another node | Backing disk/PV lost |
|---|---|---|---|
| `mode: pvc`, disk-backed KLM | survives | survives, subject to disk zone | empty |
| `mode: pvc`, in-memory KLM | empty | empty | empty |
| `mode: emptyDir` | empty; container-only crashes may preserve disk-backed-KLM stores | empty | empty |
| `mode: hostPath`, in-memory KLM | empty | empty | empty |
| `mode: hostPath`, `blockDevice.keyLocationMap: file` on node-local metadata | survives | empty | empty |

For PVC-backed storage, a node loss is normally just a reschedule: the Persistent Disk reattaches where Kubernetes can run the pod. For node-local tiers, a node loss is a disk loss. That is expected for cache-only local SSD designs; the tradeoff is a bounded window of colder builds.

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
| Enabling `iscc` or `fsac` on `mode: pvc` | Adds a StatefulSet claim template; requires a StatefulSet recreate |

Volatile stores do not lose anything extra from these changes because they already restart empty.

## Monitoring

The most useful capacity signal is worst-case retention:

```text
time() - buildbarn_blobstore_old_current_new_location_blob_map_last_removed_old_block_insertion_time_seconds
```

This is the age of the youngest data ever evicted. In plain English, it is the minimum amount of time a blob is guaranteed to survive. Keep it comfortably above your longest build, plus any window where Bazel may still need remote outputs. The chart records per-shard min/max values and ships a `BuildbarnCacheRetentionLow` alert at 24 hours.

Watch the key-location map separately:

```text
buildbarn_blobstore_hashing_key_location_map_put_too_many_iterations_total
buildbarn_blobstore_hashing_key_location_map_get_too_many_attempts_total
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

### Resize a Store

Plan the resize as a cache flush. Resize the key-location map in the same change, because block capacity and map capacity are coupled. For PVC-backed storage, confirm the StorageClass has `allowVolumeExpansion: true`; otherwise plan to recreate the StatefulSet and claims.

After the change:

- retention starts near zero and climbs as real builds refill the cache
- KLM dropped-put and exhausted-get alerts stay quiet
- storage pod memory is still within request if the map is in memory

### Scale Storage Shards

Change `storage.replicas` and run `helm upgrade`. The chart regenerates the rendezvous-hash shard map. Adding one shard remaps only the share that now belongs to that shard; it should look like a temporary miss-rate dip, not a full cache loss.

> **Be careful with `configOverrides`.** If you override `common.libsonnet`, the shard map inside that override is used verbatim. It is no longer derived from `storage.replicas`. Update the override in lockstep, or new pods may receive no traffic and removed pods may still be referenced. The chart prints an install-time warning when this override is present.

### Switch Storage Backend or Mode

Switching from filesystem to raw block, PVC to hostPath, or one backend to another creates new empty storage. StatefulSet `volumeClaimTemplates` are effectively immutable, and old PVCs are retained by default. After the new storage pods are healthy and the cache is warming, delete the old orphaned claims deliberately so they stop billing.

There is no built-in data migration between filesystem and raw block stores.

### Invalidate Poisoned Action Results

If you need to force rebuilds without flushing the CAS, wrap the AC in `actionResultExpiring` with a `configOverrides` jsonnet override and set `minimumTimestamp` to now. Older ActionResults are hidden at read time.

Set both `minimumValidity` and a nonzero `maximumValidityJitter`. An explicit `'0s'` jitter panics on the first AC hit, and an unset jitter fails startup.

For volatile deployments, restarting storage pods is simpler: it flushes AC and CAS together.

The cache is disposable by design. Every runbook above trades a temporary cold-build window for correctness. The durable part is the decision process: know whether each store is persistent, resize map and blocks together, and treat geometry changes as planned flushes.
