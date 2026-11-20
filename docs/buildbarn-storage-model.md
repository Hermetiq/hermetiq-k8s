# Buildbarn Storage Model and Sizing

Read this before choosing disk sizes, enabling raw block devices, or changing storage geometry. Buildbarn storage looks simple from Kubernetes - a CAS volume (backing both RepMaxCDC `chunkStorage` and `chunkMappingStorage` by default), an Action Cache volume, maybe ISCC and FSAC - but each enabled store is the same kind of local backend:

- a fixed-size key-location map, which is the index from digest to location
- a ring of fixed-size blocks, which holds the bytes

With RepMaxCDC content-defined chunking (`contentAddressableStorageServer`), the CAS is split into two stores:
- **`chunkStorage` (CS)**: holds compressed chunks plus small blobs (`storage.persistence.cas`). Defaults configure a 256 KiB minimum chunk size and a 2 MiB horizon; these are chunking parameters, not a claim that every chunk has that size.
- **`chunkMappingStorage` (CMS)**: maps whole-blob CAS digests to their ordered list of chunk digests (`storage.persistence.cms`, defaulting to `backend: sharedCas` on the CAS filesystem/metadata volume). Its file-backed index and persistent state survive process restarts by default. Shared placement adds no dedicated CMS claim; raw CAS still needs its metadata claim. Upgrading the old encoding requires the explicit cutover below.

With the default chunking parameters, blobs at least 512 KiB require mappings.
Setting CMS `keyLocationMap.type: inMemory` makes those blobs unavailable after
a process restart even if their chunks remain on disk. A raw CAS device with
an in-memory index has no metadata filesystem, so `sharedCas` intentionally
keeps CMS in memory too. `emptyDir` storage lasts only for the Pod's lifetime.

Most surprising behavior comes from those two structures being fixed-size and tightly coupled. If the map is too small, writes can become invisible even though bytes are still on disk. If the block geometry changes, a persistent store starts empty. If the map lives in memory, durable disks do not make the store durable.

Volume provisioning is covered in the Buildbarn chart README's [Storage](../charts/buildbarn/README.md#storage) section. Raw block devices are covered in [buildbarn-block-storage.md](buildbarn-block-storage.md). Restart behavior, monitoring, and runbooks are covered in [buildbarn-storage-operations.md](buildbarn-storage-operations.md).

## Blocks: Allocation, Eviction, and Maximum Blob Size

Think of the block store as a rotating set of large buckets. Buildbarn orders the blocks from oldest to newest and keeps them in three groups:

- **old** blocks are near eviction
- **current** blocks are stable enough to read in place
- **new** blocks receive all writes

When a blob is read from an old block, Buildbarn copies it forward into a new block. That is what makes eviction LRU-like: recently used data gets refreshed. When the oldest new block fills, blocks rotate forward and the oldest old block is discarded as a whole. There is no per-blob garbage collection; the block is the unit of eviction.

The block size is derived from total storage and block counts, in whole sectors:

```text
sectors    = blocks bytes / sector size, rounded up (a file is extended to whole sectors)
block size = floor(sectors / (spareBlocks + oldBlocks + currentBlocks + newBlocks)) * sector size
```

The sector size is the host's, `max(st_blksize, page size)` — 4096 bytes on the nodes we run — not a configured value. Dividing the bytes directly overstates the block by up to one sector, and the true ceiling is the `Y` in the error below, so state the sector size you assumed when you quote a block size.

For `backend: filesystem`, `blocks bytes` is `blocksSizeGi`. For `backend: blockDevice`, it is the usable size of the whole device, which is why `blocksSizeGi` is ignored in raw block mode. `blockDevice.size` requests the PVC size; with `mode: hostPath`, even that is only documentation.

The largest storable blob is one block. A larger upload fails with an error like:

```text
Blob is X bytes in size, while this backend is only capable of storing blobs of up to Y bytes in size
```

Check this ceiling before shrinking a store if your builds produce large archives, test outputs, link artifacts, or container layers. Also keep the total block count reasonable: bb-storage refuses configurations with more than 100 blocks for a single local backend.

`spareBlocks` are not usable capacity. They give blocks that just rotated out enough time to finish in-flight reads before being reused. Too few spare blocks can surface as:

```text
No unused blocks available
```

## Choosing Block Ratios

The chart defaults follow Buildbarn's intended shape:

- `spareBlocks: 3` for every store
- CAS `newBlocks: 3`, so hot objects are spread across new blocks instead of refreshing in one big wave later
- `oldBlocks` around one third of `currentBlocks`

For the CAS, too few old blocks makes the store behave more like FIFO. Too many old blocks wastes space on duplicate refreshed data. In practice, the current group should usually be two to three times larger than the old group.

For CMS (`chunkMappingStorage`), AC, ISCC, and FSAC, `newBlocks` must be **exactly 1**. It is an equality check, so `0` is rejected as surely as `5`:

```text
The number of "new" blocks must be set to 1 for this storage type, as objects cannot be updated reliably otherwise
```

The reason is worth knowing, because the failure it prevents is silent rather than loud. These stores replace entries, and the key-location map only overwrites a record when the new location compares as *newer* — the same block at a higher offset, or a later block. With one new block, allocation is append-only, so every rewrite wins. With more than one, Buildbarn deliberately scatters writes across the newest blocks — the behaviour the CAS wants, and the reason CAS runs `newBlocks: 3` — and a rewrite can land in a lower-indexed block than the entry it replaces. The write then succeeds without changing anything, and the store keeps serving the stale value with no error anywhere. bb-storage refuses the configuration at startup rather than let that happen.

Example CAS geometry:

```yaml
storage:
  persistence:
    cas:
      oldBlocks: 8
      currentBlocks: 30
      newBlocks: 3
      spareBlocks: 3
      blocksSizeGi: 950
```

## The Key-Location Map

The key-location map, or KLM, is the index. It maps a digest key to a block, offset, and length. Buildbarn allocates it at full size when the pod starts, and it never grows on its own.

There are two placements:

- **In memory**: `keyLocationMap.entries` for filesystem stores, or `blockDevice.keyLocationMapInMemoryEntries` for raw block stores. Budget about 64 bytes per entry of eager Go heap.
- **On disk**: `keyLocationMapSizeMi` for the filesystem CAS, `keyLocationMap: { type: blockDevice, sizeMi: ... }` for the other filesystem stores, or `blockDevice.keyLocationMap: file` for raw block stores. Budget about 66 bytes per entry.

Disk-backed maps are required for restart persistence and are the chart default
for all five stores. Filesystem CAS uses `keyLocationMapSizeMi`; filesystem
CMS/AC/ISCC/FSAC use `keyLocationMap.type: blockDevice`; all dedicated raw block
stores use `blockDevice.keyLocationMap: file`. ISCC and FSAC remain disabled by
default. Shared CMS uses the CAS filesystem or raw CAS metadata volume for its
blocks, index, and state, so budget for those files too.

Older explicit `inMemory` overrides still take precedence. Remove them or apply
the [persistent profile](buildbarn-storage-operations.md#migrate-to-persistent-indexes)
after deployment values. Fresh deployments do not need that profile. The
[ephemeral opt-out](buildbarn-storage-operations.md#explicit-ephemeral-opt-out)
selects volatile indexes where supported without changing volume mode. An
in-memory map starts empty on restart even when the blocks device is durable;
filesystem CAS always has a disk-backed map and becomes pod-lifetime with
`mode: emptyDir` instead. See [What Survives a Restart](buildbarn-storage-operations.md#what-survives-a-restart)
for volume-lifetime limits.

Adopt persistent defaults during the [all-store CDC cold-cache cutover](#storage-format-cutover-and-rollback)
so the cache warms once. The new encoding invalidates old contents even for
already-persistent ISCC. For deployments already using CDC, changing index
placement starts previously volatile stores cold, while already-persistent
stores can retain data when their paths, sizes, geometry, and volumes stay
unchanged.

Use this sizing rule:

```text
usable bytes     = block size * (old + current + new)
expected objects ~= usable bytes / average object size
entries          = 2...10 * expected objects
```

The average CAS blob size depends on the workload. Bazel deployments commonly land around 25-60 KB, but measure yours with:

```text
buildbarn_blobstore_blob_access_operations_blob_size_bytes
```

ActionResults are often only 1-2 KB, so the Action Cache needs many entries even though the AC disk volume is small.

> **Do not grow disk without growing the map.** Disk capacity is measured in bytes, but KLM pressure is measured in object count. If you add disk and leave the map unchanged, the store can hold more bytes but not more indexed objects. The result is often worse eviction behavior, not better.

## What an Undersized Map Looks Like

Buildbarn's KLM is a fixed-size hash table. To avoid long probe loops, `Get()` and `Put()` have maximum attempt counts. When the table is too crowded, newer records can displace older ones, and eventually a write can be dropped from the index. The blob bytes may still be present, but there is no reachable index entry for them.

That failure mode is easy to misread. Disk usage can look healthy, writes may not return an error, and builds may report `NotFound` for blobs that were uploaded moments earlier.

Trust these metrics (renamed in CDC `bb-storage` from `buildbarn_blobstore_hashing_key_location_map_*` to `buildbarn_lossymap_hash_map_*` with `name="KeyLocationMap:<storage_type>"`):

```text
buildbarn_lossymap_hash_map_put_too_many_iterations_total
buildbarn_lossymap_hash_map_put_iterations_count{outcome="TooManyAttempts"}
buildbarn_lossymap_hash_map_get_too_many_attempts_total
```

Any sustained nonzero rate means the map is too small for the live object count. Grow the map and, if it is in memory, grow the pod memory request with it. The chart ships an alert for dropped puts.

One implementation detail worth knowing: bb-storage rounds the effective record count down to a prime number for better hash distribution. You do not normally need to tune around that, but it explains why the usable entry count may be slightly below the number you requested.

## Sharding and the Frontend Path

Each storage replica is one shard. The chart generates a rendezvous-hash shard map from `storage.replicas`, with equal weights and shard keys `"0"` through `"N-1"`.

Rendezvous hashing keeps resharding proportional:

- adding a shard remaps roughly `1/N` of keys to the new shard
- removing a shard loses only that shard's share
- renumbering shards reshuffles everything

Scale by changing `storage.replicas`; do not reorder shard keys in an override. There is no mirroring in the chart's default topology.

**A shard removed and a shard down are not the same event.** Removing a shard — scaling `storage.replicas` down — loses about `1/N` of the cache, which is acceptable for a cache-only deployment because the data is rebuildable. A shard that is merely *unavailable* is worse than proportional, and the asymmetry is in the code:

- `Get` and `Put` route one digest to one shard, so they degrade proportionally: roughly `1/N` of requests fail while the rest are served.
- `FindMissing` fans out to every shard that owns one of the digests, in an `errgroup` with a shared cancellable context, and returns the **first** error. One unreachable shard fails the whole call.

Bazel calls `FindMissingBlobs` before every upload batch, so an unavailable shard does not cost you `1/N` of your uploads — it stops them. Reads and executions continue at `(N-1)/N`; writes stop. Plan storage disruption budgets and node drains around that, and do not reason about a `PodDisruptionBudget` as if the loss were proportional.

The frontend adds one important safety layer for the Action Cache. Bazel treats an Action Cache hit as permission to skip execution, but the referenced output blobs may have been evicted from the CAS. The frontend therefore checks that the CAS still has every referenced output before returning an AC hit. If the output tree is larger than the chart's completeness-check ceiling, currently 256 MiB, the result is treated as a miss.

The sizing consequence is simple: CAS retention should comfortably exceed AC retention. If the CAS evicts outputs before the AC evicts the ActionResult, the completeness check fails and the AC hit stops helping.

### The Frontend Read-Through Cache

`frontend.readCache.enabled` puts a `readCaching` backend in front of the shard ring: a `local` block store on the frontend pod's own disk, with the sharded backend as the slow tier and a deduplicating replicator that collapses concurrent misses for the same blob into one copy.

Four properties decide how you size it.

**Writes are never cached.** Only `Get` and `GetFromComposite` consult the fast tier. Every `Put` goes straight to the shards, so the cache does nothing for upload-heavy workloads and its capacity is sized against the *read* working set.

**It does not replace the existence cache.** `ReadCachingBlobAccess` embeds the slow backend for everything it does not override, so `FindMissingBlobs` still crosses to the shards — and that is the most frequent CAS call a Bazel client makes, before every upload. The chart therefore nests `readCaching` *inside* `existenceCaching` when both are on. Leave `frontend.contentAddressableStorage.existenceCaching.enabled` alone when you turn the read cache on; they are not alternatives.

**The fast tier's block size is a correctness setting.** It derives the same way as any other block store, with `blocksSizeGi` as the blocks bytes:

```text
block size = floor(blocksSizeGi / sector size / (spareBlocks + oldBlocks + currentBlocks + newBlocks)) * sector size
```

A blob larger than one block cannot be stored in the cache at all, and the failure does not stay inside the cache. The fast `Put` fails with `InvalidArgument`. The chart's deduplicating replicator copies the whole blob before serving it, so the read fails up front with `Failed to replicate blob <digest>` (a bare `local` replicator streams while it copies and fails the read mid-stream with `Replication failed`). Either way an undersized cache turns a miss on a large blob into a **failed build**, not a slow read. There is no way to route large blobs around it; the `size_distinguishing` backend that once did this was removed from Buildbarn.

Size the block above the largest blob the frontend actually moves, measured from its own histogram — and scope the query, because every worker runs its own `readCaching` local CAS and an unscoped query reports the worker's blobs, not the frontend's:

```text
histogram_quantile(1.0, sum by (le) (rate(
  buildbarn_blobstore_blob_access_operations_blob_size_bytes_bucket{
    pod=~"frontend.*", backend_type="read_caching"
  }[7d])))
```

Both filters matter, and so does `sum by (le)` rather than `max by (le)` — a max across heterogeneous series is not a distribution. The `backend_type` label names each decorator in the stack, so the chain is directly observable and you can confirm you are reading the right one: `deadline_enforcing, existence_caching, read_caching, local_block_device, sharding, grpc`.

The chart defaults give `250 GiB / (3 + 8 + 24 + 3)` ≈ 6.58 GiB per block (7,064,088,576 bytes with 4096-byte sectors), which clears any realistic Bazel output. Shrink `blocksSizeGi` and the block shrinks with it.

**The fast tier is node ephemeral storage, and the scheduler does not know it exists.** `volume.emptyDir` is the default, and an `emptyDir` draws from the node's allocatable `ephemeral-storage`, which is the kubelet root filesystem. Where that physically lands is a property of the node pool, not of the workload: on a GKE pool created with `--ephemeral-storage-local-ssd count=N` the kubelet root is a RAID-0 of the local SSDs, so the cache gets NVMe with no opt-in from the chart at all. A pool whose local SSDs are attached raw (`--local-nvme-ssd-block`) does **not** back `emptyDir`; those devices exist for the storage tier's `backend: blockDevice`.

The trap is that `emptyDir.sizeLimit` is not a scheduling input. `kube-scheduler` reads only `resources.requests.ephemeral-storage`, so with no request the frontend is placed on any node that satisfies CPU and memory and the cache's disk claim stays invisible until kubelet evicts the pod — for exceeding `sizeLimit`, or for crossing the node's eviction threshold. `frontend.podAntiAffinity` renders `preferredDuringScheduling`, so replicas may share a node and the real claim is `replicas x sizeLimit` against one kubelet root. Set the request to match the limit whenever the read cache is on:

```yaml
frontend:
  readCache:
    enabled: true
    blocksSizeGi: 30
    volume:
      emptyDir:
        sizeLimit: 40Gi
  resources:
    requests:
      ephemeral-storage: 40Gi   # what sizeLimit allows, not what blocksSizeGi uses
```

Two things follow from setting it. The scheduler stops co-locating replicas that cannot both fit, which is the spreading `preferred` anti-affinity does not guarantee. And node-level ephemeral-storage eviction ranks pods by usage relative to their request, so a pod with no request ranks worst — the read cache is the last pod you want evicted under disk pressure. Note also that while `validate.yaml` checks `blocksSizeGi < volume.emptyDir.sizeLimit` when `sizeLimit` is set, nothing validates `keyLocationMapInMemoryEntries` or max blob size against `blocksSizeGi` on the frontend read cache, so sizing both is on you.

Two more settings that are easy to copy wrongly from the storage tier:

- `keyLocationMapInMemoryEntries` is resident memory on the **frontend** pod at 64 bytes per entry — the chart default of 20971520 is about 1.3 GiB — and it should be sized against what fits in *this* cache, not copied from the storage tier's value. [Do not grow disk without growing the map](#what-an-undersized-map-looks-like) applies here exactly as it does to a shard, and the read cache makes it unusually easy to violate, because `blocksSizeGi` and the map are separate values that nothing relates to each other:

  ```text
  live capacity    = block size * (old + current + new)
  objects that fit = live capacity / mean size of a blob that enters the cache
  entries          = 2 to 10 * objects that fit
  ```

  Spare blocks hold no data, so they do not count toward capacity — but they still divide the block size, so they shrink both numbers at once. And the mean size of a blob that *enters* the cache is not the mean size of a blob that is *requested*: the first is what the replicator actually copied, and it is the one this formula wants. Raise `blocksSizeGi` without raising `entries` and the map fills before the disk does, which is the `TooManyAttempts` failure above — blobs on disk that the index can no longer reach.
- Note: `dataIntegrityValidationCache` was removed from `local.BlobAccessConfiguration` in CDC `bb-storage` (integrity validation is now performed per RepMaxCDC chunk and via `chunkMappingValidating`).

A worker's CAS is the one place this shape appears without an existence cache, and that is deliberate: a worker never serves `FindMissingBlobs` to anyone.

## Worked Example 1: One Local-NVMe Shard (680 GiB)

The supplied `custom-values/buildbarn-values-local-ssd-block.yaml` intentionally
uses in-memory indexes. Its provisioner creates raw LVs without a same-SSD
metadata filesystem. Boot-disk metadata is unsafe: after SSD replacement the
old index can report missing blobs as present. See the
[local SSD requirements](buildbarn-block-storage.md#gke-example-b-local-nvme-ssd-with-partition_ephemeral_disks)
before enabling persistence on this layout.

**1. Block geometry.** A 680GiB CAS device with `3 + 8 + 30 + 3 = 44` total
blocks gives about 15.5GiB per block and `41/44`, about 634GiB, usable capacity.

**2. Expected objects.** At the illustrative 17,408-byte average chunk size,
that is roughly 39.1 million live chunks. Measure your CDC chunk distribution;
assuming larger objects undersizes the index.

**3. Volatile index capacity.** The overlay uses 80M CAS entries, about `2x`
capacity, plus AC 16M, ISCC 8M, and FSAC 8M. Shared CMS also uses RAM. Enable
`storage.keyLocationMapSizing.validate` to catch undersizing before deployment.
The 112M entries occupy about 6.7GiB of heap, plus roughly 256MiB CMS index and
264MiB CMS blocks, before GC and RPC buffers. The example requests 12Gi and
limits memory to 24Gi; measure the workload.

**4. Persistent alternative.** First provision and validate a metadata
filesystem on the same Local SSD storage and a paired device/metadata reset
lifecycle. The chart's raw-CAS file default of 7360Mi holds about 116.9M records:
it is intentionally generous for the default 200Gi device (~10.2x), retaining
the existing file-index size for deployments sized near 1TiB. It gives about
`3x` for this 680Gi shard. A cold cutover is the opportunity to choose a smaller
reviewed size; resizing an already-persistent index discards its contents.
Shared CMS adds 1Gi blocks and 256Mi index. All default raw indexes plus shared
CMS blocks require about 10.75GiB, so plan at least 16GiB of same-SSD metadata
space and memory for the page-cache working set. `metadata.size` does not impose
a hostPath quota. This persistent provisioner is not supplied or GKE-validated
by this PR; the bundled overlay remains volatile.

## Worked Example 2: 10 TiB Multi-Shard Production Cache (5–10 Shards)

Suppose you are sizing a **10 TiB persistent CAS** across either **`10 shards × 1 TiB`** or **`5 shards × 2 TiB`**.

**1. Usable capacity and object count per shard.**
- **1 TiB shard (`blocksSizeGi: 950`, 10 shards)**: `950 GiB * 41 / 44 ≈ 885.2 GiB` usable per shard (`~8.85 TiB` cluster-wide), max blob size `~21.6 GiB`. At `17,408` B/blob, each shard holds **~54.6 million** CAS objects.
- **2 TiB shard (`blocksSizeGi: 1900`, 5 shards)**: `1900 GiB * 41 / 44 ≈ 1770.5 GiB` usable per shard (`~8.85 TiB` cluster-wide), max blob size `~43.2 GiB`. At `17,408` B/blob, each shard holds **~109.2 million** CAS objects.

**2. Map entries.** At 66 bytes per disk record, a **`7,680 MiB` (`7.5 GiB`)** map holds **~122.0M entries** for a 1 TiB shard, and a **`15,360 MiB` (`15 GiB`)** map holds **~244.0M entries** for a 2 TiB shard. Both give about `2.23x` the estimated live object count. A map that size belongs on disk, not on the Go heap, where it would also be lost on every restart: use `backend: filesystem` with `keyLocationMapSizeMi: 7680` / `15360`, or `backend: blockDevice` with `blockDevice.keyLocationMap: file` on a companion `12Gi` / `20Gi` `-meta` PVC. Either way `bb-storage` `mmap`s `cdc-v1/keys.db` and checkpoints `cdc-v1/persistent_state` with a 300s minimum sync interval, so the index survives restarts. Delayed syncs can leave a longer window of unsynchronized writes. Keep CMS persistent too, and include its blocks and index when sizing the shared volume.

**3. Memory.** Each lookup makes up to 16 random 66-byte probes into the mmap'd map, so budget page-cache memory for its working set. Budget the total KLM size across CS, CMS, AC, ISCC and FSAC plus about 6 GiB: `storage.resources.requests.memory: 16Gi` (`limits: 24Gi`) for 1 TiB shards and `28Gi` (`limits: 40Gi`) for 2 TiB shards. Remeasure average chunk and mapping sizes after migration rather than assuming the old whole-blob distribution remains unchanged.

**4. The other stores.** Scale AC to `20Gi–32Gi` per shard (`keyLocationMap` `sizeMi: 2688–4096`), ISCC to `1Gi–2Gi` blocks (`sizeMi: 256–512`), and FSAC to `8Gi–12Gi` (`sizeMi: 1024–1536`), all with persistent KLMs. Complete values for both shard layouts, plus frontend, scheduler, and gateway settings, are in the chart README's [Large-scale deployments](../charts/buildbarn/README.md#large-scale-deployments-10-tib-cache--510-shards) section; shutdown and grace-period behaviour is covered in [buildbarn-storage-operations.md](buildbarn-storage-operations.md#what-survives-a-restart).

**5. Verify with production traffic.** After a few days, check that blobs are not discarded before they are reused (for example, cache misses or `NOT_FOUND` errors for recently uploaded outputs, and AC hits failing completeness checks) and that the KLM dropped-put alert stays quiet. The eviction-age gauge (insertion age of the last removed block) is useful context, but it resets on restart and on its own proves neither that eviction happened nor that the cache is big enough. If either signal is wrong, resize the blocks and the map together.

Do this arithmetic before the first install when you can. Changing block counts, block size, or map placement later is a cache flush, as described in [buildbarn-storage-operations.md](buildbarn-storage-operations.md).

## Checked Automatically

Two of the limits above fail at startup rather than degrade, so the BB Config Editor assistant reports them as advisories on an edit instead of waiting to be asked. The rule identifiers, for cross-referencing an advisory back to this document:

| Rule | What it catches | Section |
| --- | --- | --- |
| `mutable_store_new_blocks` | `newBlocks` other than 1 on the Action Cache, ISCC or FSAC | [Choosing Block Ratios](#choosing-block-ratios) |
| `too_many_blocks` | `spareBlocks + oldBlocks + currentBlocks + newBlocks` above 100 in one local backend | [Blocks: Allocation, Eviction, and Maximum Blob Size](#blocks-allocation-eviction-and-maximum-blob-size) |

The division of labour is deliberate: the assistant owns the structural rules, which are checkable and verified against bb-storage source; this document owns the sizing arithmetic, worked examples and runbooks, which are what a generated rule list cannot give you. A test in the assistant's repository asserts that every rule identifier appears here, so a new rule cannot ship without a place to read about it.

## CMS Placement and Persistence

With `storage.persistence.cms.backend: sharedCas` (the default), CMS uses the CAS's existing mounts under the same `cdc-v1/` boundary:

| CAS layout | CMS blocks, index and checkpoint state |
| --- | --- |
| Filesystem CAS | `/storage-cas/cdc-v1/cms-blocks.db`, `/storage-cas/cdc-v1/cms-keys.db`, `/storage-cas/cdc-v1/cms_persistent_state` |
| Raw CAS with file-backed index | The same names under `/storage-cas-meta/cdc-v1/` |
| Raw CAS with in-memory index | In memory (`blocksInMemory`, default `8 MiB × 33 = 264 MiB`); mappings are lost on restart |

The `blockDevice` CMS index setting refers to Buildbarn's block-device abstraction; here it opens a regular file. Persistence lasts only as long as the underlying volume: an `emptyDir` does not survive pod replacement. Shared placement adds no PVC. Dedicated CMS volumes/devices are opt-ins for new installations; Kubernetes cannot add a volume claim template to an existing StatefulSet in place.

Customers can explicitly choose `storage.persistence.cms.keyLocationMap.type: inMemory`. On filesystem CAS this retains the CMS blocks file but loses its mapping index on restart, so large blobs may need uploading again. The default file-backed index avoids that extra loss. Applying the persistent profile after deployment values overrides that choice and also selects a file-backed index for a dedicated raw CMS, if configured; it preserves the chosen CMS backend.

## Upgrading Configurations to CDC

The chart's templates generate CDC configuration. Existing data still requires
the [storage cutover](#storage-format-cutover-and-rollback), including installs
configured only through values. Raw Jsonnet also needs edits: `configOverrides`,
custom common libraries, `scheduler.actionRouter.custom`, and the ConfigMaps
referenced by `RbeWorker.spec.config.files` or `config.generated`. The chart
checks referenced source keys rather than assuming ConfigMap names or labels.
Migrate custom files before upgrading, using a compatible migration-tool release
when available, or make these schema edits by hand:

| Old (pre-CDC) | New (CDC) |
| --- | --- |
| `contentAddressableStorage: { ... }` at the top level of `storage.jsonnet` or `frontend.jsonnet` | `contentAddressableStorageServer: { contentAddressableStorage: { chunkStorage: ..., chunkMappingStorage: ..., cdcParameterCache: ... }, getAuthorizer, putAuthorizer, findMissingAuthorizer, maximumChunkCount: 100000 }` (and `chunkingParameters` inside `storage.jsonnet`'s `chunkStorage.local`) |
| `portal.jsonnet` (`contentAddressableStorage`, `besServiceConfiguration.database`, `databaseCleanupConfiguration`, `instanceNameAuthorizer`, `enableGraphqlPlayground`, flat `actionCache`/ISCC/FSAC) | `contentAddressableStorageServer: { contentAddressableStorage: ..., readAuthorizer: ... }`, top-level `database` + `cleanupConfiguration`, `graphqlApiServiceConfiguration`, `blobstoreServiceConfiguration: {}`, per-service `readAuthorizer`/`publishAuthorizer`, and wrapped `{ backend, readAuthorizer }` for `actionCache`, `initialSizeClassCache`, and `fileSystemAccessCache` |
| `browser.jsonnet` (`blobstore: common.blobstore`) | `bb-browser` remains pre-CDC: set `blobstore: { contentAddressableStorage: { grpc: { client: { address: 'frontend-internal:8980' } } }, actionCache: common.blobstore.actionCache }` |
| Single-store `contentAddressableStorage` (in `common.libsonnet`'s `blobstore.contentAddressableStorage`, or top-level `contentAddressableStorage` in `scheduler.jsonnet` / `asset.jsonnet`) | `{ chunkStorage: <the old backend>, chunkMappingStorage: { chunkMappingValidating: { backend: ... } }, cdcParameterCache: { cacheSize: 1000, cacheDuration: '3600s', cacheReplacementPolicy: 'LEAST_RECENTLY_USED' } }` |
| `legacyContentAddressableStorage` (fork `scheduler.jsonnet`) | `contentAddressableStorage` with the CDC `{ chunkStorage, chunkMappingStorage, cdcParameterCache }` shape |
| `dataIntegrityValidationCache: { ... }` | Remove it. Chunks are validated individually, and client-side chunk mappings by `chunkMappingValidating`. |
| `keyLocationMapInMemory` or `keyLocationMapOnBlockDevice` | `keyLocationMap: { inMemory: ... }` or `keyLocationMap: { onBlockDevice: ... }` |
| `keyLocationMapMaximumGetAttempts`, `keyLocationMapMaximumPutAttempts` | `maximumGetAttempts` and `maximumPutAttempts` inside `keyLocationMap` |
| `browserUrl` (worker, noop worker) | `portalUrl`; in `scheduler.jsonnet`, `deprecatedPortalUrl` |
| `adminHttpServers` (scheduler) | `deprecatedAdminHttpServers` |
| `adminRoutePrefix` (scheduler) | `deprecatedAdminRoutePrefix` (or remove it) |
| `zstdPool` (scheduler, worker, noop worker, remote asset) | Remove it (still supported by `bb-storage` and `bb-portal`). |

The migration command is `bep-nats buildbarn-config migrate`. It edits local files, not a live namespace. Use a released `bep-nats` binary/image that includes `--storage-cms=shared-cas` and automatic `cdc-v1/` path isolation; do not assume an older image has these options. Keep a backup of your values and custom configs, and render the target chart with your actual values into a local `target-chart` directory. Copy mounted worker ConfigMaps into the input set too; an `RbeWorker` references their names rather than containing their file contents.

For example, with the compatible binary on `PATH` and custom files in `custom-configs`:

```sh
bep-nats buildbarn-config migrate --check --storage-cms=shared-cas --chart-dir target-chart custom-configs
bep-nats buildbarn-config migrate --storage-cms=shared-cas --chart-dir target-chart custom-configs
bep-nats buildbarn-config migrate --check --storage-cms=shared-cas --chart-dir target-chart custom-configs
```

The first check exits 1 when changes are needed; the write and final check must exit 0. Exit 2 needs manual attention. Inspect the diff and apply the migrated files to your values/ConfigMaps before `helm upgrade`. Confirm all store paths (CAS, shared CMS, AC, ISCC, FSAC) use `cdc-v1/` on their parent mounts and follow the explicit reset below so legacy files are retired before starting CDC storage. Verification checks configuration, not available disk space or live startup. No Docker connection to Kubernetes is needed: if using Docker, mount these local input and rendered-chart directories into the container and invoke the same command there.

The CDC cutover starts cold. An earlier lab run reused legacy files and observed 0/2571 hits on the first build and 2571/2571 on the repeat, with a data-integrity error logged once per node. That experiment does not establish a safe in-place upgrade: the chart now refuses legacy files and requires the explicit [storage cutover](#storage-format-cutover-and-rollback) below. Budget for cache refill; do not bypass the guard based on those lab results.

The worker in `RbeWorker` and the image pins also move together. A pinned pre-CDC `bb-worker` or `bb-runner-installer` image rejects the CDC worker config, so remove the pin (the operator then uses the images the chart publishes) or update it to the CDC release in the same change.

Before the chart switches a cluster to CDC, `helm upgrade` also checks that:

- The operator declares `hermetiq.com/cdc-compatible=true` for its selected image. Chart `0.3.13` automatically recognizes its pinned `v0.3.14` digest; verified custom builds can use the operator chart's `buildbarnCdcCompatible: true`. Version labels alone do not establish support. Set `upgradeChecks.operatorNamespace` when the operator runs in another namespace (required when live `RbeWorker` resources exist in the Buildbarn namespace).
- When `bep-nats` runs in this namespace (or the namespace configured by `upgradeChecks.hermetiqNamespace`), API and publisher Deployments declare the same capability. Deploy a verified dual-descriptor image and set the Hermetiq chart's `buildbarnCdcCompatible: true`. The currently bundled `v0.9.8` image is not declared compatible; this flag does not add functionality to it. Do not proceed with a combined deployment until that prerequisite is actually available and verified.
- Scheduler handover and `configurationReloadInterval` are off unless the selected fork implements CDC and those features (`scheduler.handover.cdcCompatibleFork: true`, with a non-upstream `images.scheduler.repository` and no pinned upstream `images.scheduler.digest`). The chart emits CDC `contentAddressableStorage` in every mode.

These cluster checks use `lookup`, so offline `helm template` and GitOps renders skip them. Check those configurations against this table before upgrading.

### Storage format cutover and rollback

The pre-CDC image (`db62041`) stores raw CAS bytes and unsuffixed protobufs for AC, ISCC, and FSAC. The CDC image (`8d2acac`) stores compressed CAS chunks and wraps AC, ISCC, and FSAC objects with `SHA256SuffixCoder` (a 32-byte SHA-256 suffix). Reopening old persistent indices causes decode/checksum failures that invalidate entire blocks (including newly written CDC data), and rolling back after CDC writes corrupts pre-CDC reads. This chart does not perform an in-place conversion. The supported cutover is an explicit **cold-cache reset during a maintenance window**.
Adopt the persistent defaults in that same window, so CDC conversion and index
placement cause one cold start rather than two. Optional ISCC and FSAC stay
disabled unless the deployment already enables them.

1. **Verify prerequisites and prepare persistent storage.**
   - Verify the compatible operator and `bep-nats` prerequisites above, and update the operator CRD separately (`kubectl apply --server-side -f charts/bb-worker-operator/crds/`).
   - Remove explicit `inMemory` overrides or apply the persistent profile after deployment values where the storage layout supports safe persistence. When carrying forward release overrides, use `--reset-then-reuse-values` to adopt new chart defaults, but remove/override explicit old `inMemory` values too. Render and lint the complete target configuration; `--reuse-values` can retain old implicit defaults as well.
   - Check filesystem PVC space for every enabled store's blocks, index, and state. Shared CMS adds `1 GiB` blocks + `256 MiB` index (`1280 MiB`) on the CAS filesystem or raw CAS metadata volume. Review index capacity and page-cache resources using the [migration checklist](buildbarn-storage-operations.md#migrate-to-persistent-indexes); prepare PVC expansion where needed.
   - For raw PVC stores, prepare filesystem metadata StorageClasses and sizes. Switching former RAM indexes to the new defaults adds `<store>-meta` claim templates, so plan to recreate the stopped StatefulSet while retaining existing blocks claims.
   - For raw local NVMe persistence, metadata must be on the same Local SSD storage with verified mount readiness and paired reset when devices/VGs are replaced. Never keep boot-disk/network metadata over lost local blocks. The bundled local SSD overlay remains explicitly volatile until that provisioner is validated. Shared CMS is part of CAS metadata. For local PVCs, use the same local StorageClass/device class for blocks and metadata and reset/delete both claims together after loss.
   - Keep existing worker image pins until the operator is ready. If migrating to inherited images, stage the current worker and runner-installer image references into the existing `buildbarn-worker-config` before removing pins to avoid a `SpecInvalid` window while the old chart lacks those keys.
2. **Drain clients and pause autoscalers/operator before scaling down.**
   - Stop new builds/cache clients and let active work finish. Record current replica counts and autoscaler settings.
   - Pause KEDA `ScaledObject`s (annotate with `autoscaling.keda.sh/paused: "true"`) and scale `RbeWorker` CRs to `0` (or pause operator reconciliation) before scaling Deployments — scaling managed Deployments directly is reverted by KEDA and `bb-worker-operator`.
   - Stop workers, `scheduler`, `frontend`, `browser`, `portal`, and `remote-asset` before stopping storage. Do not mix old and CDC writers during cutover.
3. **Stop all storage pods and take consistent snapshots.**
   - Scale `statefulset/storage` to `0` and wait until all `storage-0..N-1` pods terminate cleanly (so persistent stores flush checkpoints).
   - If rollback is required, snapshot **all** durable PVCs/devices together (for persistent raw block stores, snapshot both the raw block device and its companion `-meta` PVC at the same stopped point). Retain the old Helm values, rendered configs, `RbeWorker` manifests, and image digests.
4. **Explicitly retire legacy files on every shard.**
   - For `mode: pvc`, scaling `statefulset/storage` to `0` unmounts every shard's RWO PVCs (`cas-storage-<i>`, `ac-storage-<i>`, and if enabled `iscc-storage-<i>`, `fsac-storage-<i>`, or their `-meta` counterparts). Mount each shard's PVCs (`i = 0..replicas-1`) in a short-lived maintenance Pod/Job running as the storage UID/GID (`65534:65534` by default) to move legacy files off-volume or delete them after snapshots are verified.
   - **Ownership warning (`fsGroupChangePolicy: OnRootMismatch`):** Do **not** create directories as `root` inside a `65534`-owned PVC root; kubelet skips recursive `fsGroup` chown when the root already matches, which leaves `volume-init` unable to write. Let `volume-init` create `cdc-v1/` on startup.
   - For `mode: hostPath`, clean the configured host directories on **every** storage node. For `mode: emptyDir`, pods start with empty volumes and no manual cleanup is needed.
   - Renaming legacy files elsewhere on the same PVC does **not** free capacity; new `cdc-v1/` files must fit on the volume.

   | Store & backend | Legacy entries to retire | New CDC location |
   | --- | --- | --- |
   | Filesystem CAS | `/storage-cas/cas-keys.db`, `cas-blocks.db`, `persistent_state/` | `/storage-cas/cdc-v1/{keys.db,blocks.db,persistent_state/}` + shared CMS `cdc-v1/{cms-keys.db,cms-blocks.db,cms_persistent_state/}` |
   | Raw CAS with file index | `/storage-cas-meta/cas-keys.db`, `persistent_state/` | `/storage-cas-meta/cdc-v1/{keys.db,persistent_state/}` + shared CMS under `cdc-v1/`; blocks remain on `/dev/bb/cas` |
   | Former raw CAS with in-memory index | No persistent index to retire | Device reused; new CAS index/state and shared CMS files start on the prepared CAS metadata volume |
   | Filesystem AC / ISCC / FSAC | `/storage-<store>/<store>-keys.db`, `<store>-blocks.db`, `persistent_state/` | `/storage-<store>/cdc-v1/{<store>-keys.db,<store>-blocks.db,persistent_state/}` |
   | Raw AC / ISCC / FSAC with file index | `/storage-<store>-meta/<store>-keys.db`, `persistent_state/` | `/storage-<store>-meta/cdc-v1/{<store>-keys.db,persistent_state/}`; blocks remain on `/dev/bb/<store>` |

   For raw block stores, resetting the metadata starts an empty logical store; a full device wipe is unnecessary. CDC writes overwrite old device contents, so rollback requires the device snapshot, not just the old metadata. `volume-init` checks **all** enabled stores before creating any `cdc-v1/` directory and never deletes, moves, or converts user data, including on repeated failed starts. Missing even one shard leaves that shard stuck in `volume-init` and blocks `FindMissingBlobs` cluster-wide.
5. **Recreate claim templates where needed, then start CDC storage before clients.**
   - While storage remains at zero replicas, delete the StatefulSet with `kubectl delete statefulset storage --namespace hermetiq --cascade=orphan` if its claim templates must change. Retain all existing blocks PVCs; the reviewed upgrade recreates the StatefulSet with metadata claims. Do not use a deliberately failing Helm upgrade as the preflight.
   - While workers remain stopped, migrate custom Jsonnet/worker ConfigMaps and update any `RbeWorker` CRs that keep explicit `spec.images.worker` / `spec.images.runnerInstaller` pins to CDC images (`>= 20261102T`) or remove the pins to inherit from `buildbarn-worker-config` (live pre-CDC pins fail `helm upgrade` in `validate.yaml`). A worker ConfigMap the release itself renders through `extraObjects` is checked as rendered, since the upgrade replaces the live copy: migrate it in your values, not in the cluster. If an `RbeWorker` takes its image defaults from such a ConfigMap (its `commonConfigMapName`), publish `workerImage` and `runnerInstallerImage` there too.
   - Run `helm upgrade` with client replicas held at `0` (e.g., `--set frontend.replicas=0 --set scheduler.replicas=0 --set browser.replicas=0` plus `portal`/`remoteAsset` if enabled) so storage starts first, rather than letting `helm upgrade` immediately restart clients alongside storage.
   - Verify every `storage-0..N-1` pod completes `volume-init` and becomes Ready. Then restore client replicas (`helm upgrade` with normal replica counts), unpause KEDA `ScaledObject`s, and restore `RbeWorker` replicas. Restart any external cache clients to discard stale existence caches.
6. **Verify end-to-end.**
   - Verify both a small blob and a multi-megabyte (> 2 MiB) composite CAS upload/read through the frontend, then gracefully restart one storage shard with the same backing volumes and read both again. For hostPath, keep the pod on the same retained node; for network PVCs, also verify volume reattachment when testing rescheduling.
   - Verify a real remote build and an Action Cache hit with retained outputs after restart. When enabled, verify ISCC scheduling history and FSAC hints are retained too. Expect old entries to miss and rebuild/reupload during the initial cutover; confirm zero ZSTD decoding or SHA-256 data-integrity errors in storage logs. Check separate CS/CMS retention and KLM panels as the cache warms.

For a deliberate cold discard of raw PVC storage, stop the shard and delete/reset
both `<store>-blocks` and `<store>-meta` together (including shared CMS in CAS
metadata). Do not recreate a missing blocks claim against an old metadata claim.
Retained claims alone are not rollback copies once their blocks have been written.

For rollback, stop all CDC clients and storage again. Restore a consistent pre-CDC snapshot (both block devices and metadata volumes for raw block stores, across CAS and any persistent AC/ISCC/FSAC) and its matching old configurations/images before restarting. Without a snapshot, perform another explicit cold-cache reset — remove `/storage-<store>/cdc-v1/` (and `/storage-<store>-meta/cdc-v1/` for raw metadata volumes) across **all** stores before starting pre-CDC images so old `blocks.db` allocation does not hit `ENOSPC`. **Never** point the old binary at CDC data or restore an old raw-device index over a device that CDC has modified. Independent `helm rollback` cannot restore the storage format or `RbeWorker` resources outside the release.

An explicit ephemeral CMS remains supported, but losing its mappings on restart is intentional and tested; it is not suitable when composite CAS blobs must survive restarts. Custom `storage.jsonnet` overrides must implement an equivalent format boundary and persistence policy.
