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

Running a pre-CDC binary over a raw block store breaks the pair in the same
way. Both formats write to the same device; only the index and state are kept
apart, under `cdc-v1/` on the metadata volume. After a rollback to chart 0.9.9,
or any other start of a pre-CDC image against that device, the retained
`cdc-v1/` index and state describe blocks the old binary has overwritten.
`volume-init` does not catch this: it looks for pre-CDC file names only and
reuses an existing `cdc-v1/` directory as it is. Delete
`/storage-<store>-meta/cdc-v1/` (in `hostPath` mode, `cdc-v1/` under each
`blockDevice.metadata.hostPath.path`) for every raw store, on every shard,
before starting CDC again. The CAS metadata volume also holds the shared CMS.
Filesystem stores keep a separate blocks file per format, so their `cdc-v1/`
contents stay consistent; there `volume-init` refuses to start until the files
the pre-CDC binary recreated are retired again. The rollback procedure itself
is in the
[storage format cutover](buildbarn-storage-model.md#storage-format-cutover-and-rollback).

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
explicitly selects these same defaults. It is useful after older deployment
values that still set `inMemory`; new deployments do not need it. This is a
breaking default change: existing releases must review the migration below
before upgrading. Raw hostPath stores must supply metadata directories that
already exist on the node (their hostPath `type` now defaults to `Directory`),
and raw PVC stores can gain immutable metadata claim templates. Upgrades from
defaults that disabled ISCC and FSAC also add their data claims; explicitly set
their `enabled` flags to `false` if they are unused. At default filesystem
sizes, these claims add 2Gi for ISCC and 6Gi for FSAC per storage replica, on
StorageClass `premium-rwo` whatever class CAS and AC use: every store has its
own `storageClassName`. In `emptyDir` mode the two stores each need an
`emptyDir.sizeLimit`, and in `hostPath` mode they need their own paths when CAS
does not use the chart default path; the render fails otherwise. The
[preparation table](#migrate-to-persistent-indexes) lists what each layout
needs.

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
The chart now sets `storage.terminationGracePeriodSeconds: 120`; setting it to
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

Block geometry must match exactly for Buildbarn to reattach persistent data. Changing `spareBlocks`, `oldBlocks`, `currentBlocks`, `newBlocks`, `blocksSizeGi`, or the raw device size changes the derived block size. A persistent store discards all existing data on the next start.

Treat these as scheduled cache flushes:

| Change | Effect |
|---|---|
| Block counts, `blocksSizeGi`, or raw device size | Full flush of that store in persistent modes |
| Key-location map size or placement | Index starts empty; effectively a full flush |
| CMS index size (`cms.keyLocationMap.sizeMi`, or `cms.blockDevice.metadata.keyLocationMapSizeMi` for a dedicated raw CMS), including a changed chart default taken on upgrade | The CMS starts empty. The chunks stay in CAS, but every blob of 512 KiB or more (two or more chunks at the default chunking parameters) is unreadable and reported missing until it is uploaded again |
| `storage.replicas` increased by 1 | Roughly `1/N` of keys remap to the new shard; temporary miss-rate dip |
| `storage.replicas` decreased by 1 | Removed shard's cache share is lost |
| `mode` or `backend` switch | New empty volumes; old PVCs may be retained and orphaned |
| Enabling or disabling `iscc`, `fsac`, or a dedicated `cms` (`filesystem`/`blockDevice`) on `mode: pvc`. ISCC and FSAC are enabled by default, so an upgrade from values that never mention them enables both | Adds or removes a StatefulSet claim template; requires a [StatefulSet recreate](#recreate-the-storage-statefulset) |
| Switching raw-block KLM from `inMemory` to `file` on `mode: pvc` | Adds a `<store>-meta` claim template; requires a [StatefulSet recreate](#recreate-the-storage-statefulset) and starts empty |
| Rollback to a pre-CDC chart, or any other start of a pre-CDC binary, over a raw block store | The old binary overwrites the device that the `cdc-v1/` index and state describe. Delete `cdc-v1/` from that store's metadata volume before starting CDC again; see [What Survives a Restart](#what-survives-a-restart) |

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
| Writes fail with `No unused blocks available` | Reads are pinning old blocks and there are too few spare blocks | Raise `spareBlocks`; this is a geometry change and flushes persistent stores |

## Runbooks

### Migrate to Persistent Indexes

Persistent indexes are now the chart default for all five stores in both
filesystem and raw-block backends. The chart keeps existing sizes, block
geometry, paths, and memory-resource defaults; it does not migrate old contents or
provision missing hostPath filesystems automatically.

For pre-CDC deployments, use one coordinated maintenance window for the
[storage format cutover](buildbarn-storage-model.md#storage-format-cutover-and-rollback)
and these new defaults. Stop clients and storage, reset all old stores, prepare
metadata volumes and claim templates, and start CDC with persistent indexes.
That format change invalidates even previously persistent ISCC history; keeping
old PVCs cannot avoid the cold start. The steps below are the capacity and values
checklist for that cutover. Only deployments already on CDC should use the
same-format rollout in step 5 instead of the complete cutover runbook.

Remove old explicit `inMemory` overrides, or apply
[`custom-values/buildbarn-values-persistent.yaml`](../custom-values/buildbarn-values-persistent.yaml)
after deployment values to override them. The profile only changes index types;
it preserves ISCC/FSAC enable flags and does not change backends, volume mode,
block geometry, index sizes, paths, StorageClasses, or resources. CMS retains its configured
backend, including the default `sharedCas`. Within CDC, already-persistent
stores keep their paths and sizes. To deliberately retain volatile indexes, use
the [ephemeral opt-out](#explicit-ephemeral-opt-out) instead.

1. **Capture the current configuration.** Save the current release values and
   rendered manifest, and retain your deployment values file. Inspect
   `helm get values buildbarn --namespace hermetiq --all` for inherited settings.
   `--reuse-values` cannot render 0.10.0. It substitutes the old chart's
   defaults for the new ones, so every key added in 0.10.0 is missing and the
   render stops on an error that does not name the flag, such as
   `storage.persistence.cms.backend must be one of: sharedCas, filesystem,
   blockDevice`. Nothing is applied. Pass the complete values files, or use
   `helm upgrade --reset-then-reuse-values` when carrying forward the
   release's overrides: it starts with new chart defaults, then applies stored
   explicit values and the new command-line overrides. It still retains explicit
   `inMemory` settings; remove or override them deliberately. It also retains
   every value an earlier upgrade passed with `--set`. Replica counts held at
   `0` during a cut-over are stored that way and are carried into each later
   upgrade until an explicit value replaces them, so pass the real counts when
   restoring clients and check `helm get values buildbarn --namespace hermetiq`
   for leftovers. Do not combine it with `--reuse-values` or `--reset-values`,
   which take precedence. See the
   [Helm upgrade reference](https://helm.sh/docs/helm/helm_upgrade/). An
   upgrade flag alone cannot migrate volumes or repair stale checkpoints. Check for
   `configOverrides` that replace the generated storage config. If the deployment
   already uses CDC and existing persistent contents must be retained, keep its
   shard count, backend, block size, and index size unchanged. Compare the
   rendered sizes with the running configuration instead of assuming a default
   did not move: `storage.persistence.cms.keyLocationMap.sizeMi` now defaults to
   1280, and taking a changed index default resizes that index and empties its
   store unless the old value is pinned. The pre-CDC cutover is already cold, so
   reviewed capacity changes can share that maintenance window. Step 4 gives the
   commands that show the chart's guards and NOTES warnings before anything is
   applied.

2. **Check capacity for every enabled store.** A disk index uses 66 bytes per
   record, so `index MiB >= desired entries × 66 / 1048576`, rounded up. Continue
   sizing entries against blob capacity, not only the current working set.
   `keyLocationMap.entries` and `keyLocationMapInMemoryEntries` stop controlling
   capacity once the index moves to a file; review `keyLocationMap.sizeMi` or
   `blockDevice.metadata.keyLocationMapSizeMi` instead. The chart's sizing guard
   uses the same 66-byte disk-record size; the roughly 64-byte in-memory entry
   estimate does not size file indexes. Keep space for state and filesystem
   metadata. Include shared CMS in the CAS filesystem or metadata-volume budget:
   its defaults add 1Gi of blocks and a 1280Mi index (2304Mi). The default
   1000Gi CAS claim and the default 10Gi raw CAS metadata claim both hold it; a
   smaller customized claim may not, and the render then fails. A dedicated
   filesystem CMS claim defaults to 4Gi for the same two files. For example,
   the default filesystem AC uses 10Gi blocks plus a 1344Mi index inside a 12Gi
   claim; a customized 11Gi blocks file would not fit. These checks read the
   values, not the live claim: an existing claim keeps the size it was created
   with, so compare the output of `kubectl get pvc --namespace hermetiq` with
   the rendered sizes and expand a claim that is too small before starting
   storage. Budget page-cache memory and sync I/O too: the raw-CAS file
   default is 7360Mi, much larger than the former default 24M-entry RAM map
   (~1.43GiB). The five default file indexes total 10304Mi (10.06GiB) on
   filesystem backends (CAS 7168, CMS 1280, AC 1344, ISCC 256, FSAC 256) and
   11008Mi (10.75GiB) with raw CAS/AC/ISCC/FSAC and shared CMS (CAS 7360, CMS
   1280, AC 1344, ISCC 512, FSAC 512), before CMS blocks, Go heap, and I/O
   buffers. The unchanged 4Gi memory request does not reserve that working set:
   size requests and limits for the expected page cache and workload. The
   profile deliberately does not resize indexes or adjust resource limits.

   The sizing guard divides usable bytes by
   `storage.keyLocationMapSizing.averageObjectSizeBytes`, which is the size of
   one stored record. Do not measure it from
   `buildbarn_blobstore_blob_access_operations_blob_size_bytes`. On the CDC
   image that histogram records the size named in the request digest, not the
   stored record: the uncompressed chunk for `storage_type="cs"` (the stored
   chunk is ZSTD-compressed and smaller), the whole blob for `cms`, and the size
   in the digest that keys the record for `ac`, `iscc`, and `fsac`. For CAS, AC,
   ISCC, and FSAC use, per `storage_type` on the storage pods,
   `buildbarn_blobstore_flat_blob_access_refreshes_size_bytes_sum` divided by
   `buildbarn_blobstore_flat_blob_access_refreshes_blobs_sum`. Both stay at zero
   until data has aged into the old blocks, so they cannot confirm sizing right
   after a cold cutover or a reset. For CMS use `32 + 36 × (mean blob size / mean
   chunk size)` bytes per mapping, never below 104; the comment above
   `storage.keyLocationMapSizing` in the chart's `values.yaml` gives the inputs.
   The default CMS index is sized for that 104-byte floor rather than for the
   guard's 512-byte default, because resizing it later empties the CMS. After
   the cutover, the dropped-put and exhausted-get counters under
   [Monitoring](#monitoring) are the check that an index is large enough.

3. **Prepare storage according to the existing backend.**

   | Existing store | Preparation and migration |
   |---|---|
   | Filesystem + PVC | Ensure the existing claim has room for the index and state at the paths listed below, and on the CAS claim for the shared CMS files; no new claim is needed for an already-enabled store. Keep its blocks file and geometry unchanged. ISCC and FSAC are now enabled, so unless values set `enabled: false` the StatefulSet gains two claim templates, `iscc` (2Gi) and `fsac` (6Gi), one claim each per replica. Their StorageClass defaults to `premium-rwo` whatever class CAS uses: set `storage.persistence.iscc.storageClassName` and `storage.persistence.fsac.storageClassName` before the claims are created, because a claim keeps the class it was created with. NOTES prints `WARNING: STORAGE CLASS MISMATCH` when a filesystem store's class differs from the CAS class. The added templates require [StatefulSet recreation](#recreate-the-storage-statefulset). |
   | Filesystem + hostPath | Ensure free space in the existing `hostPath.path`; recovery remains limited to that retained node and filesystem. ISCC and FSAC are now enabled and each mounts its own `hostPath.path`. Give both an explicit path next to the other stores, or set `enabled: false`. When CAS is a raw block device or `cas.hostPath.path` is not the chart default, the render refuses an ISCC or FSAC still on the chart default path (`/mnt/stateful_partition/kube-ephemeral-ssd/buildbarn-storage/<store>`): where that is not a mounted SSD, the kubelet creates the directory on the node boot disk. AC is not checked; set its path yourself. |
   | Filesystem + emptyDir | Ensure `emptyDir.sizeLimit` fits the blocks and index. ISCC and FSAC are now enabled, and each needs `storage.persistence.<store>.emptyDir.sizeLimit` (their PVC defaults are 2Gi and 6Gi) or `enabled: false`; the render fails otherwise. Container restarts may recover, but replacing the pod still loses the store. |
   | Raw block + PVC | Set each store's `blockDevice.metadata.storageClassName` and `blockDevice.metadata.size`. The metadata class defaults to `premium-rwo` whatever class the blocks use. For node-local blocks set it to the blocks' local StorageClass/device class, never network metadata: TopoLVM deletes only its own claims when a node is deleted, so a metadata claim on another class survives and is reattached to new, blank blocks. NOTES prints `WARNING: STORAGE CLASS MISMATCH` when the two classes differ. Adding `<store>-meta` requires [StatefulSet recreation](#recreate-the-storage-statefulset). Reuse blocks only with fresh metadata for the cold cutover; when discarding a store, reset/delete its blocks and metadata claims together. |
   | Raw block + hostPath | Supply a retained filesystem `blockDevice.metadata.hostPath.path` for every enabled raw store. The directory must already exist: `blockDevice.metadata.hostPath.type` now defaults to `Directory` (it was `DirectoryOrCreate`), so a missing directory fails the volume mount and the pod does not start, where before the kubelet created it on the boot disk. This adds pod volumes, not PVC templates, so no StatefulSet recreation is needed. Stores left on the filesystem backend follow the "Filesystem + hostPath" row. |

   CAS uses `cdc-v1/keys.db`; AC/ISCC/FSAC use
   `cdc-v1/<store>-keys.db`, with `cdc-v1/persistent_state/` alongside each map.
   Shared CMS uses `cdc-v1/cms-{blocks,keys}.db` and
   `cdc-v1/cms_persistent_state/` on the CAS filesystem or metadata volume; it
   needs no separate claim or hostPath. Dedicated CMS uses `cms-keys.db` and
   `persistent_state/` directly under `/storage-cms` or `/storage-cms-meta`, and
   requires the same capacity and metadata review as the other stores.

   The bundled Local SSD layout provides the raw hostPath metadata directories.
   The provisioner in
   [`custom-values/partition-ephemeral-disks-daemonset.yaml`](../custom-values/partition-ephemeral-disks-daemonset.yaml)
   creates a 16Gi metadata filesystem on the same SSDs as the data LVs, mounts
   it at `/mnt/stateful_partition/buildbarn-local-ssd/metadata`, creates the
   `cas`, `ac`, `iscc`, and `fsac` directories in it, and labels the node
   `hermetiq/ephemeral-lvm=ready` only after verifying the mount. The overlay
   [`custom-values/buildbarn-values-local-ssd-block.yaml`](../custom-values/buildbarn-values-local-ssd-block.yaml)
   schedules storage on that label and sets these paths:

   ```yaml
   storage:
     persistence:
       cas:
         blockDevice:
           metadata:
             hostPath: { path: /mnt/stateful_partition/buildbarn-local-ssd/metadata/cas, type: Directory }
       ac:
         blockDevice:
           metadata:
             hostPath: { path: /mnt/stateful_partition/buildbarn-local-ssd/metadata/ac, type: Directory }
       iscc:
         blockDevice:
           metadata:
             hostPath: { path: /mnt/stateful_partition/buildbarn-local-ssd/metadata/iscc, type: Directory }
       fsac:
         blockDevice:
           metadata:
             hostPath: { path: /mnt/stateful_partition/buildbarn-local-ssd/metadata/fsac, type: Directory }
   ```

   A Local SSD pool provisioned before this layout has no metadata LV and
   cannot gain one in place. Follow the
   [cut-over procedure for an existing Local SSD pool](buildbarn-block-storage.md#cut-over-procedure-for-an-existing-local-ssd-pool).

   With your own layout, provide the same things yourself: a filesystem on the
   same storage as the blocks, one existing directory per raw store inside it,
   and a scheduling gate on the verified mount. Reset the matching metadata
   whenever a data device is recreated. `Directory` avoids silently creating
   absent paths on the boot disk; it does not itself verify mount identity, so
   point each path at a directory inside the mounted filesystem, not at the
   mountpoint, which exists on the boot disk whether or not anything is mounted.
   Shared CMS uses CAS metadata; dedicated raw CMS needs its own directory too.

   `metadata.size` provisions a PVC only in PVC mode; it does not reserve or
   enforce hostPath space. Node-local metadata cannot protect lost Local SSD
   blocks. Surviving node replacement requires durable storage for both. The new
   enabled defaults add ISCC/FSAC data claims unless existing values explicitly
   disable them. Plan these claims in the same cutover; switching shared CMS
   to a dedicated volume also adds claim templates.

4. **Render and inspect before upgrading.** From the repository root, apply the
   profile after deployment values, and any reviewed sizing/path overrides last:

   ```bash
   helm template buildbarn ./charts/buildbarn --namespace hermetiq \
     -f deployment-values.yaml \
     -f custom-values/buildbarn-values-persistent.yaml \
     -f persistence-overrides.yaml \
     --set storage.keyLocationMapSizing.validate=true > buildbarn-persistent-rendered.yaml
   ```

   Use an empty `persistence-overrides.yaml` or omit that argument if no overrides
   are needed. Compare with the saved manifest: check file-index paths,
   `persistent.stateDirectoryPath`, volume mounts, init permissions, and expected
   claim additions. Verify block sizes, device paths, shard count, and unrelated
   settings are unchanged. A later `inMemory` override intentionally opts that
   store back out.

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
     -f deployment-values.yaml \
     -f custom-values/buildbarn-values-persistent.yaml \
     -f persistence-overrides.yaml
   ```

   It applies nothing. It runs the `lookup` checks an offline render skips: the
   CDC capability declarations, live `RbeWorker` and worker ConfigMap contents,
   and the comparison of the live `storage` StatefulSet's claim templates with
   the rendered ones (see
   [Recreate the Storage StatefulSet](#recreate-the-storage-statefulset)). It
   also prints NOTES at the end of its output. Read the storage lines there:
   `WARNING: VOLATILE STORAGE STORES`, `WARNING: STORAGE INDEX CAPACITY`,
   `WARNING: STORAGE CLASS MISMATCH`, and the `emptyDir` warning. A bare
   `--dry-run` is a client-side render and skips the same checks. A GitOps
   tool that renders with `helm template` runs neither the lookup checks nor
   NOTES.

5. **Perform the reviewed migration.** For pre-CDC, use the coordinated
   [cutover runbook](buildbarn-storage-model.md#storage-format-cutover-and-rollback),
   including the stopped-StatefulSet recreation when claims change. For an
   already-CDC deployment, schedule a cold-cache window, because
   each previously volatile store starts empty on the first conversion. Drain
   builds first; if CAS or CMS is reset, restart frontends before resuming clients
   so stale positive existence-cache entries cannot hide missing blobs. When
   the claim templates change (raw PVC stores gaining `<store>-meta` claims,
   ISCC or FSAC being enabled, a dedicated CMS), follow
   [Recreate the Storage StatefulSet](#recreate-the-storage-statefulset) with
   storage stopped: the upgrade is refused until the old StatefulSet object is
   gone. Otherwise, use a normal upgrade with the same file order:

   ```bash
   helm upgrade buildbarn ./charts/buildbarn --namespace hermetiq --reset-then-reuse-values \
     -f deployment-values.yaml \
     -f custom-values/buildbarn-values-persistent.yaml \
     -f persistence-overrides.yaml
   ```

   Keep the reviewed values in subsequent upgrades. If older deployment files
   retain `inMemory`, keep the persistent profile after them or remove those
   overrides. Confirm healthy storage pods and successful metadata mounts, then
   verify retained history/cache entries through a controlled graceful restart
   after the store has warmed and persisted state. Allow enough termination
   grace time for the disks to sync. Abrupt failures can still lose unsynchronized
   writes as described above.

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
when raw CAS has no metadata filesystem. Raw stores no longer need metadata
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
is a separate migration and must not be used to discard an existing release's
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

Kubernetes rejects changes to a StatefulSet's `volumeClaimTemplates`. Enabling
or disabling ISCC/FSAC or a dedicated CMS on `mode: pvc`, adding raw-block
metadata claims, switching a store's backend, or changing a claim's size or
class therefore needs the StatefulSet object deleted and created again. The
PVCs are kept. ISCC and FSAC are enabled by default, so upgrading a `mode: pvc`
release from chart 0.9.9 with values that never mention them is one of these
changes. Helm does not recreate the object for you. It patches every other
object of the release, the StatefulSet patch is then refused, and the release
is left failed and half-applied.

The chart refuses such a release before anything is applied. On a
`helm install` or `helm upgrade` against the cluster it looks up the live
StatefulSet named `storage` in the release namespace and fails when its claim
templates differ from the rendered ones. For a default 0.9.9 release upgraded
with default values the error is:

```text
live StatefulSet hermetiq/storage has different volumeClaimTemplates than this release renders: claim template "fsac" is added; claim template "iscc" is added. Kubernetes forbids changing volumeClaimTemplates in place, and Helm applies every other object of the release before that patch is refused, which leaves the release half-applied on the old StatefulSet. Stop storage first (scale statefulset/storage to 0 and wait for its pods to terminate), run `kubectl delete statefulset storage --namespace hermetiq --cascade=orphan`, then run this upgrade again so the StatefulSet is recreated with the rendered templates. Existing PersistentVolumeClaims are kept as they are: a changed class or size only applies to claims that do not exist yet. The same recreation is needed when rolling back to a revision whose claim templates differ; helm rollback does not run this check. Set upgradeChecks.skipStorageClaimTemplateCheck=true to skip it. See https://github.com/Hermetiq/hermetiq-k8s/blob/main/docs/buildbarn-storage-model.md#storage-format-cutover-and-rollback
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

For a pre-CDC upgrade, the
[storage format cutover](buildbarn-storage-model.md#storage-format-cutover-and-rollback)
owns the whole sequence: it stops all writers and storage, retires the old
files, and recreates the StatefulSet at zero replicas, as in the stopped
recreation below. Only the stopped recreation is valid there. Nothing in this
section makes mixed pre-CDC and CDC storage safe.

**Stopped recreation.** Use this whenever a claim name is added or removed, or
a claim has to be deleted to change its class.

1. Render the intended chart and values and run the server-side dry run from
   step 4 of [Migrate to Persistent Indexes](#migrate-to-persistent-indexes).
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
   the persistent profile and any sizing/path overrides. Helm creates the
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
storage and delete the StatefulSet first, then roll back. A rollback across the
storage format is a cold cutover of its own; follow the rollback steps of the
[storage format cutover](buildbarn-storage-model.md#storage-format-cutover-and-rollback).

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
