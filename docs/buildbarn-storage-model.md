# Buildbarn Storage Model and Sizing

Read this before choosing disk sizes, enabling raw block devices, or changing storage geometry. Buildbarn storage looks simple from Kubernetes - a CAS volume, an Action Cache volume, maybe ISCC and FSAC - but each enabled store is the same kind of local backend:

- a fixed-size key-location map, which is the index from digest to location
- a ring of fixed-size blocks, which holds the bytes

Most surprising behavior comes from those two structures being fixed-size and tightly coupled. If the map is too small, writes can become invisible even though bytes are still on disk. If the block geometry changes, a persistent store starts empty. If the map lives in memory, durable disks do not make the store durable.

Volume provisioning is covered in the main guide's [Planning](../README.md#planning) section. Raw block devices are covered in [buildbarn-block-storage.md](buildbarn-block-storage.md). Restart behavior, monitoring, and runbooks are covered in [buildbarn-storage-operations.md](buildbarn-storage-operations.md).

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

For AC, ISCC, and FSAC, keep `newBlocks: 1`. These stores update existing entries, and bb-storage only guarantees reliable updates for mutable stores when there is one new block. If you configure more, bb-storage refuses to start.

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

Scale by changing `storage.replicas`; do not reorder shard keys in an override. There is no mirroring in the chart's default topology. Losing one shard loses about `1/N` of the cache, which is acceptable for cache-only deployments because the data is rebuildable.

The frontend adds one important safety layer for the Action Cache. Bazel treats an Action Cache hit as permission to skip execution, but the referenced output blobs may have been evicted from the CAS. The frontend therefore checks that the CAS still has every referenced output before returning an AC hit. If the output tree is larger than the chart's completeness-check ceiling, currently 256 MiB, the result is treated as a miss.

The sizing consequence is simple: CAS retention should comfortably exceed AC retention. If the CAS evicts outputs before the AC evicts the ActionResult, the completeness check fails and the AC hit stops helping.

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

**5. Verify with production traffic.** After a few days, worst-case retention should stay above your target and the KLM dropped-put alert should remain quiet. If either signal is wrong, resize the blocks and the map together.

Do this arithmetic before the first install when you can. Changing block counts, block size, or map placement later is a cache flush, as described in [buildbarn-storage-operations.md](buildbarn-storage-operations.md).
