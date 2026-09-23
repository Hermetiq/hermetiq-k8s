# Buildbarn Storage Model and Sizing

Read this before choosing disk sizes, enabling raw block devices, or changing storage geometry. Buildbarn storage looks simple from Kubernetes - a CAS volume, an Action Cache volume, maybe ISCC and FSAC - but each enabled store is the same kind of local backend:

- a fixed-size key-location map, which is the index from digest to location
- a ring of fixed-size blocks, which holds the bytes

Most surprising behavior comes from those two structures being fixed-size and tightly coupled. If the map is too small, writes can become invisible even though bytes are still on disk. If the block geometry changes, a persistent store starts empty. If the map lives in memory, durable disks do not make the store durable.

Volume provisioning is covered in the Buildbarn chart README's [Storage](../charts/buildbarn/README.md#storage) section. Raw block devices are covered in [buildbarn-block-storage.md](buildbarn-block-storage.md). Restart behavior, monitoring, and runbooks are covered in [buildbarn-storage-operations.md](buildbarn-storage-operations.md).

## Blocks: Allocation, Eviction, and Maximum Blob Size

Think of the block store as a rotating set of large buckets. Buildbarn orders the blocks from oldest to newest and keeps them in three groups:

- **old** blocks are near eviction
- **current** blocks are stable enough to read in place
- **new** blocks receive all writes

When a blob is read from an old block, Buildbarn copies it forward into a new block. That is what makes eviction LRU-like: recently used data gets refreshed. When the oldest new block fills, blocks rotate forward and the oldest old block is discarded as a whole. There is no per-blob garbage collection; the block is the unit of eviction.

The block size is derived from total storage and block counts:

```text
block size = blocks bytes / (spareBlocks + oldBlocks + currentBlocks + newBlocks)
```

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

For AC, ISCC, and FSAC, `newBlocks` must be **exactly 1**. It is an equality check, so `0` is rejected as surely as `5`:

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

Disk-backed maps are required for restart persistence. On `backend: filesystem`, the CAS is disk-backed by default. The other stores default to in-memory unless you opt in. For raw block stores, `keyLocationMap: inMemory` is the default and means cache-only behavior even when the blocks device is durable.

Use this sizing rule:

```text
usable bytes     = blocks bytes * (old + current + new) / (spare + old + current + new)
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

Trust these metrics:

```text
buildbarn_blobstore_hashing_key_location_map_put_too_many_iterations_total
buildbarn_blobstore_hashing_key_location_map_put_iterations_count{outcome="TooManyAttempts"}
buildbarn_blobstore_hashing_key_location_map_get_too_many_attempts_total
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

**The fast tier's block size is a correctness setting.** It derives the same way as any other block store:

```text
block size = blocksSizeGi / (spareBlocks + oldBlocks + currentBlocks + newBlocks)
```

A blob larger than one block cannot be stored in the cache at all, and the failure does not stay inside the cache. The fast `Put` fails with `InvalidArgument`, the replicator wraps it as `Replication failed`, and that error rides back on the buffer the client is already reading — so an undersized cache turns a miss on a large blob into a **failed build**, not a slow read. There is no way to route large blobs around it; the `size_distinguishing` backend that once did this was removed from Buildbarn.

Size the block above the largest blob the frontend actually moves, measured from its own histogram — and scope the query, because every worker runs its own `readCaching` local CAS and an unscoped query reports the worker's blobs, not the frontend's:

```text
histogram_quantile(1.0, sum by (le) (rate(
  buildbarn_blobstore_blob_access_operations_blob_size_bytes_bucket{
    pod=~"frontend.*", backend_type="read_caching"
  }[7d])))
```

Both filters matter, and so does `sum by (le)` rather than `max by (le)` — a max across heterogeneous series is not a distribution. The `backend_type` label names each decorator in the stack, so the chain is directly observable and you can confirm you are reading the right one: `deadline_enforcing, existence_caching, read_caching, local_block_device, sharding, grpc`.

The chart defaults give `250 / (3 + 8 + 24 + 3) = 6.5 GiB` per block, which clears any realistic Bazel output. Shrink `blocksSizeGi` and the block shrinks with it.

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

Two things follow from setting it. The scheduler stops co-locating replicas that cannot both fit, which is the spreading `preferred` anti-affinity does not guarantee. And node-level ephemeral-storage eviction ranks pods by usage relative to their request, so a pod with no request ranks worst — the read cache is the last pod you want evicted under disk pressure. Note also that nothing validates `blocksSizeGi` against the bounding volume here the way `storage.persistence` is checked, so keeping `blocksSizeGi` below `sizeLimit` is on you.

Two more settings that are easy to copy wrongly from the storage tier:

- `keyLocationMapInMemoryEntries` is resident memory on the **frontend** pod at 64 bytes per entry — the chart default of 20971520 is about 1.3 GiB — and it should be sized against what fits in *this* cache, not copied from the storage tier's value. [Do not grow disk without growing the map](#what-an-undersized-map-looks-like) applies here exactly as it does to a shard, and the read cache makes it unusually easy to violate, because `blocksSizeGi` and the map are separate values that nothing relates to each other:

  ```text
  live capacity    = blocksSizeGi * (old + current + new) / (old + current + new + spare)
  objects that fit = live capacity / mean size of a blob that enters the cache
  entries          = 2 to 10 * objects that fit
  ```

  Spare blocks hold no data, so they do not count toward capacity — but they still divide the block size, so they shrink both numbers at once. And the mean size of a blob that *enters* the cache is not the mean size of a blob that is *requested*: the first is what the replicator actually copied, and it is the one this formula wants. Raise `blocksSizeGi` without raising `entries` and the map fills before the disk does, which is the `TooManyAttempts` failure above — blobs on disk that the index can no longer reach.
- `dataIntegrityValidationCache` is on by default here for a reason: a file-backed fast tier re-checksums every object on every read without it, which is exactly the cost the cache exists to avoid.

A worker's CAS is the one place this shape appears without an existence cache, and that is deliberate: a worker never serves `FindMissingBlobs` to anyone.

## Worked Example: One Local-NVMe Shard

Suppose one cache-only shard has raw block devices and in-memory maps.

**1. Block geometry.** A 680 GiB CAS device with `3 + 8 + 30 + 3 = 44` total blocks gives a block size of about 15.5 GiB. That is also the largest storable blob. Usable capacity is `41/44`, or about 634 GiB.

**2. Expected objects.** At a 35 KB average blob size, 634 GiB is roughly 19 million live CAS objects.

**3. Map entries.** The 2x floor gives:

```yaml
storage:
  persistence:
    cas:
      backend: blockDevice
      blockDevice:
        keyLocationMapInMemoryEntries: 40000000
```

Use a higher multiplier if your measured average object size is smaller, if the workload has many tiny generated files, or if you see KLM saturation metrics after a few days.

**4. Memory.** In-memory maps are eager heap:

```text
CAS 40M entries * 64 B ~= 2.4 GiB
AC  10M entries * 64 B ~= 0.6 GiB
ISCC + FSAC 1M each    ~= 0.1 GiB
```

That is about 3.1 GiB before Go garbage collector headroom, gRPC buffers, and the rest of the process. A `storage.resources.requests.memory` of at least 6 GiB is a safer starting point for this example.

**5. Verify with production traffic.** After a few days, check that blobs are not discarded before they are reused (for example, cache misses or `NOT_FOUND` errors for recently uploaded outputs, and AC hits failing completeness checks) and that the KLM dropped-put alert stays quiet. The eviction-age gauge (insertion age of the last removed block) is useful context, but it resets on restart and on its own proves neither that eviction happened nor that the cache is big enough. If either signal is wrong, resize the blocks and the map together.

Do this arithmetic before the first install when you can. Changing block counts, block size, or map placement later is a cache flush, as described in [buildbarn-storage-operations.md](buildbarn-storage-operations.md).

## Checked Automatically

Two of the limits above fail at startup rather than degrade, so the BB Config Editor assistant reports them as advisories on an edit instead of waiting to be asked. The rule identifiers, for cross-referencing an advisory back to this document:

| Rule | What it catches | Section |
| --- | --- | --- |
| `mutable_store_new_blocks` | `newBlocks` other than 1 on the Action Cache, ISCC or FSAC | [Choosing Block Ratios](#choosing-block-ratios) |
| `too_many_blocks` | `spareBlocks + oldBlocks + currentBlocks + newBlocks` above 100 in one local backend | [Blocks: Allocation, Eviction, and Maximum Blob Size](#blocks-allocation-eviction-and-maximum-blob-size) |

The division of labour is deliberate: the assistant owns the structural rules, which are checkable and verified against bb-storage source; this document owns the sizing arithmetic, worked examples and runbooks, which are what a generated rule list cannot give you. A test in the assistant's repository asserts that every rule identifier appears here, so a new rule cannot ship without a place to read about it.

