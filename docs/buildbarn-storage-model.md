# Buildbarn Storage Model and Sizing

Read this before choosing disk sizes, enabling raw block devices, or changing storage geometry. Buildbarn storage looks simple from Kubernetes - a CAS volume (backing both RepMaxCDC `chunkStorage` and `chunkMappingStorage` by default), an Action Cache volume, and ISCC and FSAC volumes by default - but each enabled store is the same kind of local backend:

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

The largest **stored record** must fit in one block. In CDC `chunkStorage`, that
record is a compressed chunk or a small unchunked blob, not an entire
multi-chunk CAS blob. CMS stores an encoded mapping; AC, ISCC and FSAC store
their own encoded records. An oversized record fails with an error like:

```text
Blob is X bytes in size, while this backend is only capable of storing blobs of up to Y bytes in size
```

Check this ceiling before shrinking a store. Large archives and outputs may be
split across many CS records, but their CMS mapping must still fit in one CMS
block. Also keep the total block count reasonable: bb-storage refuses
configurations with more than 100 blocks for a single local backend.

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

The key-location map, or KLM, is the index. It maps a digest key to a block, offset, and length. Its size is fixed by configuration and it never grows on its own.

An in-memory map is allocated at full size when the pod starts. A file-backed map is not: bb-storage creates it as a sparse file, sets its length at start, and the filesystem allocates space only as records are written. The blocks file of a filesystem store is created the same way. A volume that is too small for its files therefore does not fail at start. Writes fail with `ENOSPC` later, as the store fills. The chart compares the configured file sizes with the claim size in your values, not with the live volume.

There are two placements:

- **In memory**: `keyLocationMap.entries` for filesystem stores, or `blockDevice.keyLocationMapInMemoryEntries` for raw block stores. Budget about 64 bytes per entry of eager Go heap.
- **On disk**: `keyLocationMapSizeMi` for the filesystem CAS, `keyLocationMap: { type: blockDevice, sizeMi: ... }` for the other filesystem stores, or `blockDevice.keyLocationMap: file` for raw block stores. Budget about 66 bytes per entry.

Disk-backed maps are required for restart persistence and are the chart default
for all five stores. Filesystem CAS uses `keyLocationMapSizeMi`; filesystem
CMS/AC/ISCC/FSAC use `keyLocationMap.type: blockDevice`; all dedicated raw block
stores use `blockDevice.keyLocationMap: file`. ISCC and FSAC are enabled by
default; scheduler analysis and worker prefetching remain separate opt-ins.
Shared CMS uses the CAS filesystem or raw CAS metadata volume for its
blocks, index, and state, so budget for those files too: 1 GiB of blocks plus
a 1280 MiB index (2304 MiB) by default.

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

`average object size` is the size of one **stored** record: a compressed chunk
in CS, a chunk mapping in CMS, an encoded ActionResult in the AC. It depends on
the workload. The chart's `storage.keyLocationMapSizing.averageObjectSizeBytes`
defaults are pre-CDC starting assumptions from one deployment, and the `cas`
figure (17408) is a whole-blob average taken before chunking and compression.
Replace them with figures from your own cluster.

Do not derive them from
`buildbarn_blobstore_blob_access_operations_blob_size_bytes`. On the CDC image
that histogram records the size named in the request digest, not the stored
record:

| `storage_type` | The histogram records | The store holds |
| --- | --- | --- |
| `cs` | The uncompressed chunk size | The encoded chunk; ZSTD often reduces its size, but incompressible input can incur overhead |
| `cms` | The size of the whole blob | Its chunk mapping, 104 bytes or more |
| `ac`, `iscc`, `fsac` | The size in the digest that keys the record (the Action for AC, the reduced Action for ISCC and FSAC) | The ActionResult, execution stats or access profile |

Sizing CS from it can undersize the index when compression lets more records
fit on disk. Sizing CMS from whole-blob sizes can make an undersized index look
large enough.

Use these instead, on the storage pods:

- **CMS:** `32 + 36 * (mean blob size / mean chunk size)` bytes, and never
  below 104. A stored mapping is 36 bytes per chunk (a 4-byte size and a
  32-byte SHA-256 hash) plus a 32-byte checksum suffix, and a mapping has at
  least two chunks. For a planning estimate, use that histogram's `_sum / _count`
  for `storage_type="cms", operation="Put"` as the mean blob size; this samples
  writes, not the retained mapping population. A theoretical mean chunk size is about 1.338 times
  `config.contentAddressableStorage.chunkingParameters.minChunkSizeBytes`
  (upstream's figure; about 343 KiB by default). Do not take it from the `cs`
  series, which also counts every blob small enough to be one chunk. These are
  workload-dependent estimates, not observed mapping sizes or capacity proof.
- **CS, AC, ISCC, FSAC:** per `storage_type`,

  ```text
  buildbarn_blobstore_flat_blob_access_refreshes_size_bytes_sum
    / buildbarn_blobstore_flat_blob_access_refreshes_blobs_sum
  ```

  This is the stored size of records that were read again after ageing into
  the old blocks. Both series stay at zero until data has aged that far, so
  there is nothing to read right after a cold cut-over or a reset. The same
  ratio works for CMS once it has data.

Then watch the [key-location map counters](#what-an-undersized-map-looks-like).
Either one rising means that index is too small, whatever the estimate said.

ActionResults are often only 1-2 KB, so the Action Cache needs many entries even though the AC disk volume is small.

The CMS does not scale with the CAS. Its block ring fills and rotates on its
own, so in steady state it holds `usable CMS bytes / mean mapping size`
mappings, whatever the size of the CAS. The default 1 GiB blocks file has 33 of
36 blocks usable, about 939 MiB: about 1.9 million mappings at 512 bytes and at
most about 9.5 million at the 104-byte floor. The default file index
(`storage.persistence.cms.keyLocationMap.sizeMi: 1280`, 20.3 million records)
is sized for that floor, 2.15x, because disk is cheap and resizing the index
later empties the CMS: every blob of two or more chunks is then reported
missing until it is uploaded again. `averageObjectSizeBytes.cms` stays at 512,
which is about 13 chunks, a blob of roughly 4.5 MiB. That is what the sizing
guard assumes, not what the default index is sized for.

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

Any sustained nonzero rate means the map is too small for the live object count. Grow the map and, if it is in memory, grow the pod memory request with it. The chart ships two alerts on them, `BuildbarnKeyLocationMapPutsDropped` and `BuildbarnKeyLocationMapGetsExhausted`.

Those alerts, and the six recorded `buildbarn_blobstore_hashing_key_location_map_*` series behind the dashboards, select `kubernetes_service="storage"` only. A worker's local read cache and the frontend read cache appear only in the raw `buildbarn_lossymap_hash_map_*` metrics, filtered by `kubernetes_service` (the `RbeWorker` name for a worker, `frontend` for the frontend). The records depend on that pod label: the chart's `VMPodScrape`s copy it, and a cluster with `vmPodScrapes.enabled: false` and its own scrape configuration must copy it too, or the records are empty and both alerts stay silent.

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

`frontend.readCache.enabled` wraps the CDC `chunkStorage` path in a
`readCaching` backend: a `local` block store on the frontend pod's own disk,
with sharded chunk storage as the slow tier and a deduplicating replicator
that collapses concurrent fills for the same chunk into one copy. It holds
compressed chunks and small unchunked blobs, not reconstructed multi-chunk
CAS blobs. `chunkMappingStorage` remains a separate path.

Four properties decide how you size it.

**Writes are never cached.** Reads consult the fast tier. Every `Put` goes
straight to the shards, so size this cache against the *read* working set;
uploads do not populate it.

**It does not replace the existence cache.** `ReadCachingBlobAccess` embeds the slow backend for everything it does not override, so `FindMissingBlobs` still crosses to the shards — and that is the most frequent CAS call a Bazel client makes, before every upload. The chart therefore nests `readCaching` *inside* `existenceCaching` when both are on. Leave `frontend.contentAddressableStorage.existenceCaching.enabled` alone when you turn the read cache on; they are not alternatives.

**The fast tier's block size is a correctness setting.** It derives the same way as any other block store, with `blocksSizeGi` as the blocks bytes:

```text
block size = floor(blocksSizeGi / sector size / (spareBlocks + oldBlocks + currentBlocks + newBlocks)) * sector size
```

A stored record larger than one block cannot be cached. The fast `Put` fails
with `InvalidArgument`, and a failed fill can fail the read and therefore the
build. In CDC, even a bare `local` replicator completes the source read and
sink write before returning; it does not stream a whole CAS blob to the caller
while filling the cache. The chart's deduplicating wrapper coalesces fills and
reports failures as `Failed to replicate blob <digest>`. Do not assume that a
failed fill silently bypasses the cache.

Compare the per-block capacity with the largest **encoded record** passed to
this fast tier. The blob-size histogram records the request digest's size;
for CS that is the uncompressed chunk size, not the encoded record size. It
cannot establish the maximum stored size, and a bucketed quantile is not an
exact maximum. Scope telemetry to the frontend or worker being sized and use
the deployed chunking parameters and encoding when checking this ceiling.
The block does not need to fit the largest reconstructed multi-chunk output.

The chart defaults give `250 GiB / (3 + 8 + 24 + 3)` ≈ 6.58 GiB per block
(7,064,088,576 bytes with 4096-byte sectors). These are chart defaults, not
evidence of the live configuration. Shrink `blocksSizeGi` and the block shrinks
with it.

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
  objects that fit = live capacity / mean encoded chunk or small-blob size
  entries          = 2 to 10 * objects that fit
  ```

  Spare blocks hold no data, so they do not count toward capacity — but they still divide the block size, so they shrink both numbers at once. And the mean size of a blob that *enters* the cache is not the mean size of a blob that is *requested*: the first is what the replicator actually copied, and it is the one this formula wants. Raise `blocksSizeGi` without raising `entries` and the map fills before the disk does, which is the `TooManyAttempts` failure above — blobs on disk that the index can no longer reach.
- Note: `dataIntegrityValidationCache` was removed from `local.BlobAccessConfiguration` in CDC `bb-storage` (integrity validation is now performed per RepMaxCDC chunk and via `chunkMappingValidating`).

A worker's CAS is the one place this shape appears without an existence cache, and that is deliberate: a worker never serves `FindMissingBlobs` to anyone.

## Worker Local Cache and Volume Sizing

Keep these worker resources separate when assessing capacity:

- `chunkStorage.readCaching.fast.local` holds compressed chunks and small
  blobs on disk, with its own blocks and key-location map.
- `chunkCache` holds decoded, verified chunks in process memory;
  `chunkMappingCache` holds parsed mappings.
- A virtual build directory's `filePool` backs writable temporary and output
  files. It is not an input cache. Its files may share a volume with the local
  disk cache, depending on the configured paths and mounts.

Match each path to the actual volume before adding capacity budgets. For
example, 16 GiB of cache blocks, a 200 MiB index and a 32 GiB file pool on one
volume create a combined configured demand of about 48.2 GiB, plus state and
filesystem overhead. They do not prove the volume is overcommitted: files can
be sparse, a file pool has a configured ceiling, and an `emptyDir: {}` has no
explicit volume size limit. Check the backing filesystem's capacity and free
space, any volume quota, node ephemeral-storage pressure and colocated pods.
A limit on a different mount, such as `/worker`, does not limit the CAS volume.
Pod memory headroom cannot establish disk headroom.

`persistent` plus a file-backed index can recover only while the cache's
blocks, index and checkpoint state survive together. `emptyDir` can survive a
container restart in the same Pod, but not Pod replacement. Replacing
`spec.storage.casVolume` with one PVC is not sufficient for a scalable worker
pool: the operator copies that volume source into every replica. A shared
claim can cause mount conflicts or concurrent access to the same cache and
file-pool paths. Persistence requires exclusive storage and paths per worker,
plus stable reattachment of that worker's data. A node-local PV remains tied
to its node and does not preserve data after node or local-disk loss. Verify
these lifecycle properties before recommending a persistence conversion.

## Worker Decoded Chunk Cache

CDC worker disk caches hold compressed chunks. Reading those bytes still runs
ZSTD decompression and digest verification. Virtual build directories (FUSE or
NFS) can request different portions of the same chunk repeatedly, so a warm
disk cache can still spend substantial CPU decoding the same input. The worker's
`blobstore.contentAddressableStorage.chunkCache` retains decoded, verified
chunks in memory for subsequent reads. Integrity checks remain on cache fills.
`chunkMappingCache` holds mappings, not decoded bytes, and does not solve this
problem. Native build directories cache whole input files and have a different
reuse pattern.

The chart's worker cache is configured through
`config.contentAddressableStorage.chunkCache`. Its default is 2,048 entries,
with a one-hour lifetime and LRU eviction. It is shared across actions within
each worker process. The worker ConfigMap uses the `buildbarn.workerCommon`
template helper; custom worker ConfigMaps should use that helper too. A full
`configOverrides["common.libsonnet"]` replacement remains authoritative and must
configure the cache itself. Check the rendered worker entrypoint: defining a
cache in a shared library is insufficient if the worker reconstructs the CAS
object and drops that field.

`cacheSize` is an entry count, not a byte limit. For canonical RepMaxCDC chunks,
decoded payload is bounded by `cacheSize * 2 * minChunkSizeBytes`. With the
current 256 KiB minimum, 2,048 entries retain less than 1 GiB of payload and
4,096 retain less than 2 GiB. Allow additional memory for heap/GC overhead,
in-flight reads and other worker activity. `horizonSizeBytes` is a chunking
lookahead parameter, not the maximum chunk size. These bounds do not establish
an optimal cache size; compare CPU profiles, input-fetch timing and memory
under representative builds before increasing capacity.

Eviction counters need the same care. A `Remove`/`Insert` ratio measures
replacement activity, not hit rate, occupancy or memory headroom. Missing
`Remove` series are missing evidence, not measured zero removals. Observed
removals alone do not show that a larger cache would improve builds; correlate
them with repeated decoding, input-fetch latency and the memory budget. A
count of distinct worker Pods likewise does not establish churn or a cold-cache
penalty without their lifetimes and workload placement.

Barn Owl's `worker_chunk_cache` rule checks the effective rendered CAS of workers
with virtual build directories. A missing or null cache is performance guidance,
not proof of a measured slowdown. A configured cache whose capacity is zero,
negative or omitted is a breaking finding: bb-storage's bounded map attempts to
evict from an empty cache on insertion. A zero lifetime is guidance because
entries expire immediately. To disable the cache, omit the rendered `chunkCache` object; the
chart does this for `cacheSize: 0`. The audit lists configured cache sizes and
lifetimes, but does not declare a positive size undersized or automatically
choose a size without worker memory and workload evidence.

## Worked Example 1: One Local-NVMe Shard (718 GiB)

The supplied `custom-values/buildbarn-values-local-ssd-block.yaml` uses persistent
file indexes for all five stores. Its provisioner reserves a 16Gi metadata LV on
the same Local SSD VG as the raw data LVs, mounts it at
`/mnt/stateful_partition/buildbarn-local-ssd/metadata`, and publishes readiness
only after checking the layout and mount. Never substitute boot-disk or network
metadata: retained indexes over lost blocks can report nonexistent blobs present.
See the [local SSD requirements](buildbarn-block-storage.md#gke-example-b-local-nvme-ssd-with-partition_ephemeral_disks)
and [GKE validation runbook](buildbarn-gke-storage-validation.md).

**1. Block geometry.** On the two-SSD example, the observed CAS LV is 717.992Gi;
`size: 718Gi` rounds up for the sizing guard. With `3 + 8 + 30 + 3 = 44` total
blocks, that gives about 16.3GiB per block and `41/44`, about 669GiB, usable
capacity. Measure the actual LV when changing the node pool or device count.

**2. Expected objects.** At the illustrative 17,408-byte average chunk size,
that is roughly 41.3 million live chunks. Measure your stored chunk size as
described under [The Key-Location Map](#the-key-location-map); assuming larger
objects undersizes the index.

**3. Persistent index capacity.** The 7360Mi CAS index holds about 116.9M
records at 66 bytes each, about `2.83x` this shard's estimated live chunks.
AC uses 1344Mi, ISCC and FSAC use 512Mi each, and shared CMS uses the chart
default of 1280Mi. The overlay enables `storage.keyLocationMapSizing.validate` to catch undersizing
before deployment. The raw-CAS chart default retains this generous file size
for deployments near 1TiB; on its default 200Gi device it provides about `10.2x`.
Choose a smaller reviewed size during a cold cutover if desired; resizing an
already-persistent index discards its contents.

**4. Metadata and memory.** All five indexes total 11008Mi (10.75GiB); shared CMS
adds a 1Gi blocks file, for 12032Mi (11.75GiB) of files. The 16Gi metadata LV
leaves room for checkpoint state and filesystem overhead. `metadata.size` does
not impose a hostPath quota. File indexes still consume memory for their
resident pages, alongside Go heap, GC, CMS blocks and RPC buffers. The example
requests 16Gi and limits memory to 24Gi; measure page-cache pressure and the
workload before reducing these limits.
Storage pod restarts reuse retained blocks and metadata. SSD loss or replacement
requires resetting both together and starts cold; an old full VG without the
metadata LV cannot be reused and needs the
[cut-over procedure for an existing Local SSD pool](buildbarn-block-storage.md#cut-over-procedure-for-an-existing-local-ssd-pool).

## Worked Example 2: 10 TiB Multi-Shard Production Cache (5–10 Shards)

Suppose you are sizing a **10 TiB persistent CAS** across either **`10 shards × 1 TiB`** or **`5 shards × 2 TiB`**.
The arithmetic below uses 17,408 bytes per stored CS record as an illustrative
assumption inherited from pre-CDC measurements. It is not a measured compressed
chunk size or a recommended value for your deployment. Substitute your stored
record sizes before choosing index and memory capacities.

**1. Usable capacity and object count per shard.**
- **1 TiB shard (`blocksSizeGi: 950`, 10 shards)**: `950 GiB * 41 / 44 ≈ 885.2 GiB` usable per shard (`~8.64 TiB` cluster-wide), per-block stored-record ceiling `~21.6 GiB`. At the assumed `17,408` B/record, each shard holds **~54.6 million** CS records.
- **2 TiB shard (`blocksSizeGi: 1900`, 5 shards)**: `1900 GiB * 41 / 44 ≈ 1770.5 GiB` usable per shard (`~8.64 TiB` cluster-wide), per-block stored-record ceiling `~43.2 GiB`. At the assumed `17,408` B/record, each shard holds **~109.2 million** CS records.

**2. Map entries.** At 66 bytes per disk record, a **`7,680 MiB` (`7.5 GiB`)** map holds **~122.0M entries** for a 1 TiB shard, and a **`15,360 MiB` (`15 GiB`)** map holds **~244.0M entries** for a 2 TiB shard. Both give about `2.23x` the estimated live object count of a filesystem shard. A map that size belongs on disk, not on the Go heap, where it would also be lost on every restart: use `backend: filesystem` with `keyLocationMapSizeMi: 7680` / `15360`, or `backend: blockDevice` with `blockDevice.keyLocationMap: file` on a companion `-meta` PVC. A raw device is all blocks (about 954 GiB and 1908 GiB usable), so the same maps cover it only `2.07x`; use `8192` / `16384` MiB (`2.21x`) on a `12Gi` / `24Gi` `-meta` PVC there. Either way `bb-storage` `mmap`s `cdc-v1/keys.db` and checkpoints `cdc-v1/persistent_state` with a 300s minimum sync interval, so the index survives restarts. Delayed syncs can leave a longer window of unsynchronized writes. Keep CMS persistent too, and include its blocks and index when sizing the shared volume: 2304 MiB at the defaults (step 4), which the `12Gi` / `24Gi` `-meta` claims above hold next to the CAS index.

**3. Memory.** Each lookup makes up to 16 random 66-byte probes into the mmap'd map, so budget page-cache memory for its working set. Budget the total KLM size across CS, CMS, AC, ISCC and FSAC plus about 6 GiB: `storage.resources.requests.memory: 20Gi` (`limits: 28Gi`) for 1 TiB filesystem shards and `28Gi` (`limits: 40Gi`) for 2 TiB, or `22Gi` and `30Gi` for raw-block shards with the larger maps above. Remeasure stored chunk and mapping sizes after migration, with the method under [The Key-Location Map](#the-key-location-map), rather than assuming the old whole-blob distribution remains unchanged.

**4. The other stores.** Scale AC to `20Gi–32Gi` per shard (`keyLocationMap` `sizeMi: 2688–4096`), ISCC to `1Gi–2Gi` blocks (`sizeMi: 256–512`), and FSAC to `8Gi–12Gi` (`sizeMi: 1024–1536`), all with persistent KLMs.

CMS is sized on its own terms, not in proportion to the CAS. The chart default is a 1 GiB blocks file (`storage.persistence.cms.blocksSizeGi: 1`) with a 1280 MiB index (`storage.persistence.cms.keyLocationMap.sizeMi: 1280`), 2304 MiB together on the CAS filesystem or the raw CAS metadata volume. The steady-state number of mappings is the usable CMS bytes divided by the mean stored mapping size, regardless of CAS size: about 939 MiB usable holds about 1.9 million mappings at 512 bytes and at most about 9.5 million at the 104-byte floor, and the 20.3-million-record index covers that floor 2.15x. A mapping is only useful while its chunks are still in CS, so judge the CMS by retention: if `storage_type="cms"` discards blocks sooner than `storage_type="cs"`, blobs of two or more chunks are reported missing and uploaded again although their chunks are still stored. In that case raise `blocksSizeGi` and `keyLocationMap.sizeMi` together; 1280 MiB of index per GiB of blocks keeps the index above 2x at the floor. Decide before the first install or in a cold cut-over, because resizing either one later empties the CMS.

Complete values for both shard layouts, plus frontend, scheduler, and gateway settings, are in the chart README's [Large-scale deployments](../charts/buildbarn/README.md#large-scale-deployments-10-tib-cache--510-shards) section; shutdown and grace-period behaviour is covered in [buildbarn-storage-operations.md](buildbarn-storage-operations.md#what-survives-a-restart).

**5. Verify with production traffic.** After a few days, check that blobs are not discarded before they are reused (for example, cache misses or `NOT_FOUND` errors for recently uploaded outputs, and AC hits failing completeness checks) and that the KLM dropped-put alert stays quiet. The eviction-age gauge (insertion age of the last removed block) is useful context, but it resets on restart and on its own proves neither that eviction happened nor that the cache is big enough. If either signal is wrong, resize the blocks and the map together.

Do this arithmetic before the first install when you can. Treat later changes
to block counts, block size or map placement as potentially cache-invalidating
and plan for a cold cache. Preservation must be verified against the exact
geometry and retained state; see
[buildbarn-storage-operations.md](buildbarn-storage-operations.md#changes-that-flush-the-cache).

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

The `blockDevice` CMS index setting refers to Buildbarn's block-device abstraction; here it opens a regular file. Persistence lasts only as long as the underlying volume: an `emptyDir` does not survive pod replacement. Shared placement adds no PVC, but it adds 2304 MiB of files by default (a 1 GiB blocks file and a 1280 MiB index) to the volume it shares. A dedicated filesystem CMS (`backend: filesystem`) gets its own `cms` claim, `4Gi` by default, which holds the same two files. Dedicated CMS volumes/devices are opt-ins for new installations; Kubernetes cannot add a volume claim template to an existing StatefulSet in place.

Customers can explicitly choose `storage.persistence.cms.keyLocationMap.type: inMemory`. On filesystem CAS this retains the CMS blocks file but loses its mapping index on restart, so large blobs may need uploading again. The default file-backed index avoids that extra loss. Applying the persistent profile after deployment values overrides that choice and also selects a file-backed index for a dedicated raw CMS, if configured; it preserves the chosen CMS backend.

## Upgrading Configurations to CDC

The chart's templates generate CDC configuration. Existing data still requires
the [storage cutover](#storage-format-cutover-and-rollback), including installs
configured only through values. Raw Jsonnet also needs edits: `configOverrides`,
custom common libraries, `scheduler.actionRouter.custom`, and the ConfigMaps
referenced by `RbeWorker.spec.config.files` or `config.generated`. The chart
refuses the upgrade when it finds pre-CDC configuration in any of them;
[What the upgrade checks cover](#what-the-upgrade-checks-cover) lists what it
reads and what it cannot detect. Migrate custom files by hand before
upgrading, using this table:

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

Keep a backup of your values and custom configs before editing. Include the worker ConfigMaps that pools mount: an `RbeWorker` references them by name and does not contain their files. In custom storage configuration, put every store path (CAS, shared CMS, AC, ISCC, FSAC) under `cdc-v1/` on its parent mount, and follow the explicit reset below so legacy files are retired before CDC storage starts. To check the result, run the upgrade with `--dry-run=server`: it runs the chart's checks, including the ones that read the cluster, and applies nothing. Those checks read configuration as text; they do not prove that a component starts.

The CDC cutover starts cold. An earlier lab run reused legacy files and observed 0/2571 hits on the first build and 2571/2571 on the repeat, with a data-integrity error logged once per node. That experiment does not establish a safe in-place upgrade: the chart now refuses legacy files and requires the explicit [storage cutover](#storage-format-cutover-and-rollback) below. Budget for cache refill; do not bypass the guard based on those lab results.

The worker in `RbeWorker` and the image pins also move together. A pinned pre-CDC `bb-worker` or `bb-runner-installer` image rejects the CDC worker config, so remove the pin (the operator then uses the images the chart publishes) or update it to the CDC release in the same change. The same applies to the release's own `images.*` values: remove `tag` and `digest` overrides carried over from the old release.

`bb-browser` also changes its network path. It is still a pre-CDC binary, so it no longer reads the CAS from the storage shards: it reads it through the frontend on port 8980, at `frontend-internal:8980`, or at `frontend-grpc:8980` when `frontend.internalService.enabled` is `false`. It still reads the Action Cache from storage on 8981. If your own NetworkPolicy restricts ingress to the frontend pods, admit the `app: browser` pods on TCP 8980 before upgrading, or Browser pages that load CAS content time out.

### What the upgrade checks cover

`validate.yaml` refuses a release that would start pre-CDC binaries on CDC configuration, or CDC binaries on pre-CDC configuration. The checks read text, tags and annotations. Passing them does not prove that a configuration loads.

**Configuration text.** The chart reads Jsonnet as text. Nothing is evaluated and imports are not followed. It reads:

- every `configOverrides` entry and `scheduler.actionRouter.custom`;
- the keys that an `RbeWorker` in the release namespace references through `spec.config.files` (`configMapName`, `items`; every key when `items` is unset) or `spec.config.generated` (`commonConfigMapName`, `commonItems`), from the live ConfigMap. When the release itself renders that ConfigMap through `extraObjects`, the rendered copy is read instead, since the upgrade replaces the live one: every YAML document of the entry, and every item of a `List`;
- every key of any other ConfigMap in the release namespace whose name ends in `-worker-config` or that carries the `hermetiq.com/worker-pool` label, unless an `RbeWorker` owns it. No `RbeWorker` has to reference it. A backup copy of a pre-CDC worker configuration with such a name or label blocks this upgrade and every later one: rename it, delete it, or keep it in another namespace. The error says when a ConfigMap was selected this way. The chart's own `buildbarn-config` and `buildbarn-worker-config` are not read.

A removed field is recognised bare or quoted, followed by `:`, `::` or `+:`, after block comments, `//` comments and lines starting with `#` are removed. A `contentAddressableStorage` definition counts as CDC when the file sets `chunkStorage`, `chunkMappingStorage`, `chunkMappingCache`, `cdcParameterCache` or `chunkCache`, or refers to `common.blobstore.contentAddressableStorage`.

What it cannot do:

- It does not see computed keys such as `['zstdPool']:`, fields assembled by code, or anything behind an `import`.
- `//` inside a string hides the rest of that line, so a removed field later on the line is missed. A `#` after other text is not treated as a comment, so a field name there is matched.
- `browserUrl` is matched as a word anywhere outside a comment, including inside a string.
- Setting one of the CDC fields anywhere in a file, or mentioning `common.blobstore.contentAddressableStorage`, exempts the whole file from the single-store check, even around a pre-CDC decorator. Delegating through an import alias other than `common` is refused as pre-CDC.
- An `RbeWorker` that references a missing ConfigMap fails the upgrade even at zero replicas. `RbeWorker` resources outside the release namespace are not read.

**Images.** The chart refuses a tag that carries an upstream date stamp before `20261102` on `images.storage`, `images.scheduler`, `images.worker` and `images.runnerInstaller`, on `images.remoteAsset` and `images.portal` when those components are enabled, and on a live `RbeWorker`'s `spec.images.worker` or `spec.images.runnerInstaller`, including the `workerImage` and `runnerInstallerImage` defaults of its referenced ConfigMap. `images.browser` is not checked, because `bb-browser` stays pre-CDC on purpose. Only the upstream `YYYYMMDDThhmmssZ-<commit>` tag form can be classified. A re-tagged mirror image, a digest-only reference, and a stale `digest` override left next to a new tag are all accepted, for the release's images and for `RbeWorker` pins alike. Check those by hand.

**Scheduler fork features.** `scheduler.handover.enabled` and `scheduler.configurationReloadInterval` are refused unless the selected fork implements CDC and those features (`scheduler.handover.cdcCompatibleFork: true`, with a non-upstream `images.scheduler.repository` and no pinned upstream `images.scheduler.digest`). Turning both off for the upgrade is not enough while `images.scheduler` still pins a fork built without CDC support: that scheduler rejects the CDC configuration with or without the features, so remove its `repository`, `tag` and `digest` overrides as well. The chart emits CDC `contentAddressableStorage` in every mode.

**Cluster state.** The remaining checks read live objects with `lookup`:

- The worker operator and Hermetiq are not checked. bb-worker-operator `1.0.0` generates CDC worker configuration only and Hermetiq `1.0.0` reads the CDC schema only; upgrade both in the same window as this chart. With an older operator the worker pools crash-loop on pre-CDC configuration until it is upgraded.
- The live `RbeWorker` pins and worker ConfigMaps described above.
- The live `storage` StatefulSet has the same `volumeClaimTemplates` as the release renders; see step 1 of the [storage cutover](#storage-format-cutover-and-rollback).

These checks run on `helm install` as well as `helm upgrade`. When the account running Helm may not list `RbeWorker` objects or ConfigMaps, Helm stops with a `forbidden` error; `upgradeChecks.skipWorkerChecks` turns the worker checks off, and `upgradeChecks.skipConfigTextCheck` turns off the text scan when it refuses configuration that is valid CDC. Verify by hand what a skipped check would have verified. They are skipped wherever `lookup` returns nothing: offline `helm template`, client-side dry runs, and GitOps tools that render client-side (Argo CD renders with `helm template`). Check those configurations against this section by hand, or run the real command with `--dry-run=server`, which performs the lookups and applies nothing.

### Storage format cutover and rollback

The pre-CDC image (`db62041`) stores raw CAS bytes and unsuffixed protobufs for AC, ISCC, and FSAC. The CDC image (`06739f2`) stores compressed CAS chunks and wraps AC, ISCC, and FSAC objects with `SHA256SuffixCoder` (a 32-byte SHA-256 suffix). Reopening old persistent indices causes decode/checksum failures that invalidate entire blocks (including newly written CDC data), and rolling back after CDC writes corrupts pre-CDC reads. This chart does not perform an in-place conversion. The supported cutover is an explicit **cold-cache reset during a maintenance window**: every store on every shard starts empty, and builds refill the cache.
Adopt the persistent defaults in that same window, so CDC conversion and index
placement cause one cold start rather than two. ISCC and FSAC are now enabled
by default. In `mode: pvc` that adds two claim templates to every release that
did not already enable both, and the `storage` StatefulSet must then be deleted
and recreated in this window (steps 1 and 5). Keep an explicit `enabled: false`
for both stores to avoid the new claims. The persistent and ephemeral profiles
preserve these enable flags.

1. **Verify prerequisites and prepare persistent storage.**
   - Plan the worker operator and Hermetiq upgrades for this window. bb-worker-operator `1.0.0` generates CDC worker configuration only, so it is upgraded in step 5, after the worker pools are paused and before the Buildbarn upgrade (see [Upgrading to 1.0.0](../charts/bb-worker-operator/README.md#upgrading-to-100)). Hermetiq `1.0.0` reads the CDC schema only; upgrade it in the same window.
   - Remove pre-CDC image pins from the release values: the `tag` and `digest` overrides under `images.storage`, `images.scheduler`, `images.worker`, `images.runnerInstaller`, `images.remoteAsset` and `images.portal`. The chart refuses a date-stamped pre-CDC tag there, but it cannot classify a digest-only or re-tagged image, for these values or for `RbeWorker` pins. If you turn scheduler handover and `configurationReloadInterval` off for the upgrade, also remove the `images.scheduler` override that pins a fork built without CDC support.
   - Remove explicit `inMemory` overrides or apply the persistent profile after deployment values where the storage layout supports safe persistence. When carrying forward release overrides, use `--reset-then-reuse-values` to adopt new chart defaults, but remove/override explicit old `inMemory` values too. Do not use `--reuse-values`: it replaces the new chart's defaults with the old release's values, so every key introduced in `0.10.0` is missing and the render fails (the first error names `storage.persistence.cms.backend`). Render and lint the complete target configuration.
   - **Plan to delete and recreate the `storage` StatefulSet in step 5.** Kubernetes forbids changing `volumeClaimTemplates` in place. In `mode: pvc`, every release that did not already enable both ISCC and FSAC gains `iscc` and `fsac` claim templates, and every raw block store that moves from a RAM index to the file default gains a `<store>-meta` template. Only a release whose templates come out identical skips the recreation: one that already had both stores enabled (and file indexes on its raw stores), or one that sets `storage.persistence.iscc.enabled: false` and `storage.persistence.fsac.enabled: false`, which is the way to avoid the two new claims. `hostPath` and `emptyDir` releases have no claim templates.
   - The chart refuses the upgrade before anything is applied when the live claim templates differ from the rendered ones. For a default `0.9.9` release the error is:

     ```text
     live StatefulSet hermetiq/storage has different volumeClaimTemplates than this release renders: claim template "fsac" is added; claim template "iscc" is added. Kubernetes forbids changing volumeClaimTemplates in place, and Helm applies every other object of the release before that patch is refused, which leaves the release half-applied on the old StatefulSet. Stop storage first (scale statefulset/storage to 0 and wait for its pods to terminate), run `kubectl delete statefulset storage --namespace hermetiq --cascade=orphan`, then run this upgrade again so the StatefulSet is recreated with the rendered templates. Existing PersistentVolumeClaims are kept as they are: a changed class or size only applies to claims that do not exist yet. The same recreation is needed when rolling back to a revision whose claim templates differ; helm rollback does not run this check. Set upgradeChecks.skipStorageClaimTemplateCheck=true to skip it. See https://github.com/Hermetiq/hermetiq-k8s/blob/main/docs/buildbarn-storage-model.md#storage-format-cutover-and-rollback
     ```

     The check compares claim names and their order, `storageClassName`, `volumeMode` and requested size. Leave `upgradeChecks.skipStorageClaimTemplateCheck` at `false`. With the check skipped, or where it cannot run (a GitOps tool that renders client-side, or `helm rollback`), the ConfigMaps and client Deployments are applied first and the StatefulSet update is refused afterwards, which leaves the release half-applied.
   - Set the StorageClass of the new claims. The `iscc` and `fsac` claims and every raw `<store>-meta` claim use their own `storageClassName`, not the CAS one, and each defaults to `premium-rwo` (`storage.persistence.iscc.storageClassName`, `storage.persistence.fsac.storageClassName`, `storage.persistence.<store>.blockDevice.metadata.storageClassName`). On a cluster without that class the new claims stay Pending, `storage-0` stays Pending with them, and no other shard is created. For node-local blocks, give the metadata claim the same local class as its blocks. TopoLVM deletes only its own claims when a Node is deleted, so metadata on any other class survives while the blocks are recreated blank, and the surviving index then reports blobs that no longer exist. A real install or upgrade prints `WARNING: STORAGE CLASS MISMATCH` in its notes when a filesystem store's class differs from the CAS class, or a raw store's metadata class differs from its blocks class; `helm template` prints no notes.
   - An existing claim is reused by name (`<template>-storage-<ordinal>`, for example `cas-storage-0` or `cas-meta-storage-0`). The recreated StatefulSet creates only the claims that do not exist yet, so a class or size changed in values does not change a claim that already exists. List the claims first (`kubectl -n hermetiq get pvc`). To move metadata to another class, delete the claim itself while storage is stopped, so that it is created again from the new template. To grow a claim, expand the PVC itself and confirm its new capacity before starting storage. The chart's size checks read your values, not the live claim, and index files are sparse, so an undersized live claim starts normally and fails with `ENOSPC` as the store fills.
   - Check filesystem PVC space for every enabled store's blocks, index, and state. Shared CMS adds `1 GiB` blocks + `1280 MiB` index (`2304 MiB`) on the CAS filesystem or raw CAS metadata volume. Review index capacity and page-cache resources using the [migration checklist](buildbarn-storage-operations.md#migrate-to-persistent-indexes); prepare PVC expansion where needed.
   - For raw PVC stores, prepare filesystem metadata StorageClasses and sizes for the new `<store>-meta` claims. The existing blocks claims are retained.
   - For raw local NVMe persistence, metadata must be on the same Local SSD storage with verified mount readiness and paired reset when devices/VGs are replaced. Never keep boot-disk/network metadata over lost local blocks. In `mode: hostPath` each `blockDevice.metadata.hostPath.path` must already exist on the node: its `type` now defaults to `Directory`, so a missing metadata mount fails the pod instead of being created on the boot disk. The bundled local SSD overlay uses the provisioner's same-SSD metadata LV. An existing Local SSD pool cannot be switched in place, because the new provisioner refuses a volume group laid out by the old one: follow the [cut-over procedure for an existing Local SSD pool](buildbarn-block-storage.md#cut-over-procedure-for-an-existing-local-ssd-pool). [buildbarn-gke-storage-validation.md](buildbarn-gke-storage-validation.md) is the validation procedure and record for that layout, not a migration runbook. Shared CMS is part of CAS metadata. For local PVCs, use the same local StorageClass/device class for blocks and metadata and reset/delete both claims together after loss.
   - Decide how each `RbeWorker` gets its images after the cut-over: remove `spec.images.worker` and `spec.images.runnerInstaller` to inherit the images this chart publishes in `buildbarn-worker-config`, or update the pins to CDC images. Make the change in step 5, with the pools paused.
2. **Drain clients and pause autoscalers/operator before scaling down.**
   - Stop new builds/cache clients and let active work finish. Record current replica counts and autoscaler settings (`kubectl -n hermetiq get deployments,statefulsets,scaledobjects,rbeworkers`).
   - Suspend GitOps reconciliation of the Buildbarn release and of the `RbeWorker` manifests (Argo CD automated sync and self-heal, a Flux `HelmRelease` or `Kustomization`) before any manual step, and keep it suspended until step 5 is complete. A reconciling controller reverts `kubectl scale` and the patches below, and puts back the old StatefulSet that step 5 deletes.
   - Pause each worker pool through its `RbeWorker`, not on the worker `ScaledObject` or Deployment. `bb-worker-operator` replaces every annotation on a worker `ScaledObject` with `spec.autoscaling.scaledObjectAnnotations` on each reconcile, so a `kubectl annotate` there is removed again, and it does not apply `spec.replicas` to a pool with `spec.autoscaling.enabled: true`. For each autoscaled pool:

     ```sh
     kubectl -n hermetiq patch rbeworker <pool> --type merge \
       -p '{"spec":{"autoscaling":{"scaledObjectAnnotations":{"autoscaling.keda.sh/paused-replicas":"0"}}}}'
     ```

     KEDA then scales the pool to zero and stops autoscaling it, and the pause survives the step 5 upgrade. For a pool without autoscaling, set its replicas instead:

     ```sh
     kubectl -n hermetiq patch rbeworker <pool> --type merge -p '{"spec":{"replicas":0}}'
     ```

     The operator does not write replicas for a pool with `spec.manageReplicas: false`; stop such a pool through whatever scales it. If the `RbeWorker` manifests are applied from files, make the same change there so that a later apply does not undo it.
   - Pause the chart's own frontend `ScaledObject`, which exists when `keda.enabled` and `keda.frontend.enabled` are both true, by annotating it directly. The chart renders no annotations on it, and `helm upgrade` leaves this one in place:

     ```sh
     kubectl -n hermetiq annotate scaledobject frontend autoscaling.keda.sh/paused-replicas=0 --overwrite
     ```

   - Stop the remaining clients before stopping storage:

     ```sh
     kubectl -n hermetiq scale deployment/scheduler-ubuntu22-04 deployment/frontend deployment/browser --replicas=0
     kubectl -n hermetiq scale deployment/bb-portal --replicas=0      # when portal.enabled
     kubectl -n hermetiq scale deployment/remote-asset --replicas=0   # when remoteAsset.enabled
     ```

     Wait until no worker, scheduler, frontend, browser, portal or remote-asset pod is left (`kubectl -n hermetiq get pods`). Do not mix old and CDC writers during cutover.
3. **Stop all storage pods and take consistent snapshots.**
   - Scale `statefulset/storage` to `0` and wait until all `storage-0..N-1` pods terminate cleanly (so persistent stores flush checkpoints).
   - If rollback is required, snapshot **all** durable PVCs/devices together (for persistent raw block stores, snapshot both the raw block device and its companion `-meta` PVC at the same stopped point). Retain the old Helm values, rendered configs, `RbeWorker` manifests, and image digests.
4. **Explicitly retire legacy files on every shard.**
   - For `mode: pvc`, scaling `statefulset/storage` to `0` unmounts every shard's `ReadWriteOnce` PVCs. The claims that hold legacy files are `cas-storage-<i>`, `ac-storage-<i>` and, if enabled, `iscc-storage-<i>` and `fsac-storage-<i>` for filesystem stores, and `cas-meta-storage-<i>`, `ac-meta-storage-<i>`, `iscc-meta-storage-<i>` and `fsac-meta-storage-<i>` for raw stores that already had a file index. The raw `<store>-blocks-storage-<i>` claims need no cleanup. Mount each shard's PVCs (`i = 0..replicas-1`) in a short-lived maintenance Pod/Job running as the storage UID/GID (`65534:65534` by default) to move legacy files off-volume or delete them after snapshots are verified.
   - Delete the maintenance Pods/Jobs and confirm they are gone before step 5. The claims are `ReadWriteOnce`: a claim that a maintenance Pod still mounts on another node keeps its `storage-<i>` pod from attaching the volume and starting.
   - **Ownership warning (`fsGroupChangePolicy: OnRootMismatch`):** Do **not** create directories as `root` inside a `65534`-owned PVC root; kubelet skips recursive `fsGroup` chown when the root already matches, which leaves `volume-init` unable to write. Let `volume-init` create `cdc-v1/` on startup.
   - For `mode: hostPath`, clean the configured directories on **every** storage node: `<store>.hostPath.path` for filesystem stores, and `<store>.blockDevice.metadata.hostPath.path` for raw stores that already had a file index. A raw block store has no host directory for its blocks, and one that kept its index in memory has nothing to clean at all. That does not make an existing Local SSD pool reusable: nodes laid out by the pre-`0.10.0` provisioner have no metadata filesystem and the new provisioner refuses their volume group, so follow the [cut-over procedure for an existing Local SSD pool](buildbarn-block-storage.md#cut-over-procedure-for-an-existing-local-ssd-pool) for them. For `mode: emptyDir`, pods start with empty volumes and no manual cleanup is needed.
   - Renaming legacy files elsewhere on the same PVC does **not** free capacity; new `cdc-v1/` files must fit on the volume.

   | Store & backend | Legacy entries to retire | New CDC location |
   | --- | --- | --- |
   | Filesystem CAS | `/storage-cas/cas-keys.db`, `cas-blocks.db`, `persistent_state/` | `/storage-cas/cdc-v1/{keys.db,blocks.db,persistent_state/}` + shared CMS `cdc-v1/{cms-keys.db,cms-blocks.db,cms_persistent_state/}` |
   | Raw CAS with file index | `/storage-cas-meta/cas-keys.db`, `persistent_state/` | `/storage-cas-meta/cdc-v1/{keys.db,persistent_state/}` + shared CMS under `cdc-v1/`; blocks remain on `/dev/bb/cas` |
   | Former raw CAS with in-memory index | No persistent index to retire | Raw PVC: the device is reused, and the new CAS index/state and shared CMS files start on the new `cas-meta-storage-<i>` claim. A Local SSD pool laid out by the bundled provisioner is not reused in place; see the [Local SSD cut-over procedure](buildbarn-block-storage.md#cut-over-procedure-for-an-existing-local-ssd-pool) |
   | Filesystem AC / ISCC / FSAC | `/storage-<store>/<store>-keys.db`, `<store>-blocks.db`, `persistent_state/` | `/storage-<store>/cdc-v1/{<store>-keys.db,<store>-blocks.db,persistent_state/}` |
   | Raw AC / ISCC / FSAC with file index | `/storage-<store>-meta/<store>-keys.db`, `persistent_state/` | `/storage-<store>-meta/cdc-v1/{<store>-keys.db,persistent_state/}`; blocks remain on `/dev/bb/<store>` |

   For raw block stores, resetting the metadata starts an empty logical store; a full device wipe is unnecessary. CDC writes overwrite old device contents, so rollback requires the device snapshot, not just the old metadata. `volume-init` checks **all** enabled stores before creating any `cdc-v1/` directory and never deletes, moves, or converts user data, including on repeated failed starts. Missing even one shard leaves that shard stuck in `volume-init` and blocks `FindMissingBlobs` cluster-wide.
5. **Delete the StatefulSet, then start CDC storage before clients.**
   - While storage remains at zero replicas, delete the StatefulSet:

     ```sh
     kubectl delete statefulset storage --namespace hermetiq --cascade=orphan
     ```

     Do this on every `mode: pvc` release, unless you have confirmed in step 1 that its claim templates stay identical. `hostPath` and `emptyDir` releases have nothing to delete. All existing PVCs are retained. The upgrade below creates the StatefulSet again from the rendered templates, and its pods then get the claims that do not exist yet (`iscc-storage-<i>`, `fsac-storage-<i>`, `<store>-meta-storage-<i>`) and reuse the others by name. Without the delete, the upgrade stops at the claim-template check from step 1 with nothing applied. Do not skip that check to use a failing upgrade as the preflight. For the same sequence outside this cut-over, see [Recreate the Storage StatefulSet](buildbarn-storage-operations.md#recreate-the-storage-statefulset).
   - **Do not run the cut-over upgrade with `--atomic`, `--rollback-on-failure` or `--cleanup-on-fail`, or under a GitOps controller that rolls back automatically.** An automatic rollback restarts pre-CDC binaries over volumes that were just retired or already rewritten by CDC, and `--cleanup-on-fail` deletes the StatefulSet this upgrade created. If the upgrade fails, leave the release failed, fix the cause and run the upgrade again. If you have to go back, follow the rollback procedure below.
   - While workers remain stopped, upgrade the worker operator: apply its `1.0.0` CRD (`kubectl apply --server-side -f charts/bb-worker-operator/crds/`; add `--force-conflicts` if Helm created the CRD and kubectl reports a conflict on `.spec.versions`), then upgrade the `bb-worker-operator` chart to `1.0.0`.
   - Still with workers stopped, migrate custom Jsonnet/worker ConfigMaps and update any `RbeWorker` CRs that keep explicit `spec.images.worker` / `spec.images.runnerInstaller` pins to CDC images (`>= 20261102T`) or remove the pins to inherit from `buildbarn-worker-config`. A pool without pins reports `SpecInvalid` until the upgrade below has published the image keys. The chart refuses a live pin whose tag carries a pre-CDC upstream date stamp; it does not detect a digest-only or re-tagged pre-CDC pin, so check those yourself. A worker ConfigMap the release itself renders through `extraObjects` is checked as rendered, since the upgrade replaces the live copy: migrate it in your values, not in the cluster. If an `RbeWorker` takes its image defaults from such a ConfigMap (its `commonConfigMapName`), publish `workerImage` and `runnerInstallerImage` there too.
   - Run `helm upgrade` with client replicas held at `0` (`--set frontend.replicas=0 --set scheduler.replicas=0 --set browser.replicas=0`, plus `--set portal.replicas=0` and `--set remoteAsset.replicas=0` if enabled) so storage starts first, rather than letting `helm upgrade` immediately restart clients alongside storage. `frontend.replicas` has no effect when `keda.enabled` and `keda.frontend.enabled` are both true: the frontend Deployment then renders no `replicas` field, and the frontend is held at zero by the `ScaledObject` pause from step 2.
   - Verify every `storage-0..N-1` pod completes `volume-init` and becomes Ready.
   - Restore client replicas with a second `helm upgrade` that states them. The `--set ...replicas=0` values from the hold are stored as release values. With `--reset-then-reuse-values` they are reused and win over the chart defaults, so running the same command again without the flags leaves the clients at zero and still reports success. Either pass every count explicitly (`--set scheduler.replicas=1 --set browser.replicas=1 ...`, with the counts recorded in step 2), or run both the hold and the restore from your complete values files without `--reset-then-reuse-values` or `--reuse-values`. Afterwards check that `helm get values buildbarn --namespace hermetiq` shows no `replicas: 0`.
   - Un-pause in the order frontend, then workers. Remove the frontend annotation; KEDA brings the frontend back to `keda.frontend.minReplicaCount`:

     ```sh
     kubectl -n hermetiq annotate scaledobject frontend autoscaling.keda.sh/paused-replicas-
     ```

     Then un-pause each worker pool through its `RbeWorker`, the same way it was paused in step 2, or restore `spec.replicas` for a pool without autoscaling:

     ```sh
     kubectl -n hermetiq patch rbeworker <pool> --type merge \
       -p '{"spec":{"autoscaling":{"scaledObjectAnnotations":{"autoscaling.keda.sh/paused-replicas":null}}}}'
     ```

     Resume GitOps reconciliation once the repository matches what is deployed.
   - Restart any external cache clients to discard stale existence caches, and tell build users what to expect: see [What build clients see](#what-build-clients-see).
6. **Verify end-to-end.**
   - Verify both a small blob and a multi-megabyte (> 2 MiB) composite CAS upload/read through the frontend, then gracefully restart one storage shard with the same backing volumes and read both again. For hostPath, keep the pod on the same retained node; for network PVCs, also verify volume reattachment when testing rescheduling.
   - Verify a real remote build and an Action Cache hit with retained outputs after restart. When enabled, verify ISCC scheduling history and FSAC hints are retained too. Expect old entries to miss and rebuild/reupload during the initial cutover; confirm zero ZSTD decoding or SHA-256 data-integrity errors in storage logs. Check separate CS/CMS retention and KLM panels as the cache warms.

For a deliberate cold discard of raw PVC storage, stop the shard and delete/reset
both `<store>-blocks` and `<store>-meta` together (including shared CMS in CAS
metadata). Do not recreate a missing blocks claim against an old metadata claim.
Retained claims alone are not rollback copies once their blocks have been written.

For rollback, stop all CDC clients and storage again (steps 2 and 3). Restore a consistent pre-CDC snapshot (both block devices and metadata volumes for raw block stores, across CAS and any persistent AC/ISCC/FSAC) and its matching old configurations/images before restarting. Without a snapshot, perform another explicit cold-cache reset — remove `/storage-<store>/cdc-v1/` (and `/storage-<store>-meta/cdc-v1/` for raw metadata volumes) across **all** stores and all shards before any pre-CDC image starts. There are two reasons. On filesystem stores the `cdc-v1/` files still occupy the volume, so the old `blocks.db` allocation hits `ENOSPC`. On raw block stores both formats write the same device and only the index and state are kept apart under `cdc-v1/`, so a `cdc-v1/` index left behind is reattached, on the next roll-forward, to blocks the pre-CDC binary has since rewritten: `FindMissingBlobs` reports blobs present that then fail when read, and each failed read releases that block and every older one, including data written since. **Never** point the old binary at CDC data or restore an old raw-device index over a device that CDC has modified.

`helm rollback` does none of this, and it has three problems of its own:

- It hits the claim-template rejection in reverse, and the chart's check does not run for a rollback. Where the two revisions have different claim templates, Helm reverts the ConfigMaps and client Deployments and then fails on the StatefulSet. With storage at zero replicas, run `kubectl delete statefulset storage --namespace hermetiq --cascade=orphan` again before `helm rollback`. The claims the CDC release added (`iscc-storage-<i>`, `fsac-storage-<i>`, `<store>-meta-storage-<i>`) stay behind unused until you delete them.
- It removes `workerImage` and `runnerInstallerImage` from `buildbarn-worker-config`, because the pre-CDC chart does not publish those keys. An `RbeWorker` whose pins were removed can then no longer resolve an image: the operator reports `SpecInvalid` and leaves the pool's existing Deployment, with its CDC images, as it is. Restore the pre-CDC `spec.images.worker` / `spec.images.runnerInstaller` pins.
- It does not roll back the worker operator. bb-worker-operator `1.0.0` cannot generate pre-CDC worker configuration, so roll the operator chart back to `0.3.12` as well before resuming worker pools.
- It cannot restore the storage format, or `RbeWorker` resources and custom ConfigMaps outside the release.

The same rule applies when rolling forward again. If a pre-CDC binary has run since the last CDC start, whether through a manual rollback, an automatic one or a pod started from the old StatefulSet, delete `cdc-v1/` on every store and every shard before starting CDC again. `volume-init` cannot detect this. It looks only for pre-CDC file names, and a pre-CDC raw store with an in-memory index leaves none.

An explicit ephemeral CMS remains supported, but losing its mappings on restart is intentional and tested; it is not suitable when composite CAS blobs must survive restarts. Custom `storage.jsonnet` overrides must implement an equivalent format boundary and persistence policy.

### What build clients see

The cut-over empties the Action Cache and the CAS together, so the servers hold no stale references afterwards. Clients can.

- **The first build after the cut is slow.** Nothing is cached. Every action runs again and every output is uploaded again.
- **Bazel retries on its own when it still holds references to remote outputs.** A Bazel server that was running before the cut can hold metadata for remote outputs it never downloaded. When it needs one of them, it gets a cache-eviction error internally and restarts the build automatically, up to `--experimental_remote_cache_eviction_retries` times (default 5 on supported Bazel versions). The user sees a build that starts over, not a failure. If the retries run out, the build fails with exit code 39 (`REMOTE_CACHE_EVICTED`); running it again is enough.
- **A wrapper that pins `--invocation_id` must retry itself.** Bazel generates a new invocation ID for each of those retries. A wrapper that passes its own `--invocation_id` should set the flag to `0`, check for exit code 39, and run the build again with a new ID.
- **Restart long-running clients that cache remote existence.** Anything that remembers which blobs the cache holds, such as a cache proxy or a CI daemon in front of the frontend, keeps skipping uploads of blobs that no longer exist. Restart it after step 5.
