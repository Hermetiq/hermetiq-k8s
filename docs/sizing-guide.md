# Sizing Hermetiq and Buildbarn

This guide turns workload numbers into starting values for the Buildbarn,
Hermetiq and worker-operator charts. It answers "how big should this be?" in the
order you need to decide it. The detailed arithmetic for each subsystem lives in
the documents it links to; read those when you set the actual values.

Every number here is a starting point. Size from the best data you have, deploy,
and check the signals in [After go-live](#after-go-live) two weeks later.

## Gather your workload numbers

Answer these first. Each one drives specific values later in this guide.

| Question | What it sizes |
| --- | --- |
| How many Bazel invocations run per day, and how many in the busiest hour? | Hermetiq ingest partitions, NATS, PostgreSQL |
| How many bytes of new cache data are written per day? | Buildbarn cache capacity |
| How many bytes per second do executors read as action inputs? | Storage shard count, node network and disks |
| How many cache requests per second (Action Cache plus CAS) do clients make? | Frontend replicas |
| How many remote actions run at once, on average and at peak, per platform (amd64, arm64)? | Worker pools, their maximum replicas, the scheduler |
| How often is the same output needed again: every few hours, daily, weekly? | The cache refresh window (`oldBlocks`) |
| How long should build data and build logs be kept? | PostgreSQL partitions, log storage |
| Which node shapes and disks can you use, and how often are nodes replaced? | Network disks or local NVMe for storage |
| Do you want Action Cache Hit Tracker (one record per cache hit)? | PostgreSQL write volume, NATS memory |

Invocation counts often include `bazel query`, `bazel info` and IDE syncs. Note
how many are real builds and tests, because those produce most of the data.

### From an existing Buildbarn cluster

Run these on the storage pods. Rates are per second; multiply by 86,400 for a
daily figure, and look at a full week so weekends are included.

| Number | How to get it |
| --- | --- |
| Data retention today | Eviction age, per shard: `time() - buildbarn_blobstore_old_current_new_location_blob_map_last_removed_old_block_insertion_time_seconds{kubernetes_service="storage",storage_type="cs"}`. See [Monitoring](buildbarn-storage-operations.md#monitoring) for what it does and does not prove. |
| Bytes written per day | Usable CS capacity divided by eviction age. Usable capacity is `blocks × (old + current + new) / (all blocks)`, which is `41/44` of the blocks file with the default geometry. This counts what the store really writes, including blobs copied forward when read. |
| Request rates | `sum by (storage_type, operation) (rate(buildbarn_blobstore_blob_access_operations_blob_size_bytes_count{kubernetes_service="storage"}[1h]))` |
| Bytes read by executors | `sum(rate(buildbarn_blobstore_blob_access_operations_blob_size_bytes_sum{kubernetes_service="storage",storage_type="cs",operation="Get"}[1h]))`. This histogram records uncompressed chunk sizes, so treat it as an upper bound. |

Do not size the key-location map from that histogram; it records request sizes,
not stored records. [The Key-Location Map](buildbarn-storage-model.md#the-key-location-map)
explains how to measure stored record sizes instead.

### From another remote cache or execution service

Usage reports from other services usually map onto the questions like this:

| Report field | Use it for |
| --- | --- |
| Invocations | Invocations per day (divide a 30-day total by 30) |
| Action Cache hits, CAS hits | Cache request rate (divide by 2,592,000 seconds for a 30-day average) |
| Bytes uploaded to the cache | New cache data per day. Buildbarn stores data as compressed, deduplicated chunks, so this is an upper bound. |
| Bytes downloaded by executors or a self-hosted cache proxy | Executor input reads |
| Remote execution minutes, per platform | Average concurrent actions: minutes in the report divided by minutes in the period (43,200 for 30 days) |

If you have neither source, run a representative CI pipeline against a trial
installation for a week and measure it there.

## Buildbarn storage

### Cache capacity: days of writes, not terabytes

Size the CAS by how many days of new writes it keeps. Data nobody reads ages out
after about `usable capacity ÷ bytes written per day`. Data that is read again
stays longer, as described in the next section.

Aim for 10 to 14 days. It must comfortably cover a weekend, your longest build,
and any time Bazel may still need remote outputs. A retention shorter than two
days means Monday's first builds re-upload and re-run whatever was last used on
Friday.

| Days kept | Usable CAS at 1 TB/day written | At 2 TB/day |
| --- | --- | --- |
| 7 | 7 TB | 14 TB |
| 10 | 10 TB | 20 TB |
| 14 | 14 TB | 28 TB |

Divide by `41/44` (with the default geometry) to get the blocks size, then by
the shard count to get the size of each shard.

### Refresh window: choosing `oldBlocks`

Blocks move from new, through current, to old, and the oldest block is
discarded whole. A read refreshes a blob, copying it forward into a new block,
only while the blob sits in an **old** block. Reads while it is in a current
block do nothing. See
[Blocks: Allocation, Eviction, and Maximum Blob Size](buildbarn-storage-model.md#blocks-allocation-eviction-and-maximum-blob-size).

So a blob survives indefinitely only if it is read at least once during the old
stretch of each pass, which lasts about:

```text
old stretch ≈ retention × oldBlocks / (oldBlocks + currentBlocks + newBlocks)
```

With the default `8 / 30 / 3`, that is about 20% of retention. Make it longer
than the longest regular gap between uses of the same output. For data used once
a day, it must be over 24 hours:

| Retention | Old stretch at `8/30/3` | At `12/26/3` |
| --- | --- | --- |
| 2.5 days | 12 hours | 18 hours |
| 5 days | 23 hours | 35 hours |
| 10 days | 47 hours | 70 hours |

More old blocks means more copying forward, which is cheap on fast disks. Keep
`currentBlocks` at least twice `oldBlocks`; see
[Choosing Block Ratios](buildbarn-storage-model.md#choosing-block-ratios).
Changing block counts after install empties the store, so decide before the
first install.

The chunk-mapping store (CMS) must keep mappings at least as long as the chunk
store keeps chunks, or multi-chunk blobs are reported missing while their chunks
are still stored. Size it with
[Worked Example 2](buildbarn-storage-model.md#worked-example-2-10-tib-multi-shard-production-cache-510-shards),
step 4.

### Shard count

Three things set the number of shards:

- **Capacity per shard.** The disk or volume size each node can carry.
- **Read throughput.** Workers read action inputs directly from the storage
  shards, not through the frontend, so executor reads divide evenly across
  shards. Assume peaks of about three times the average. Each shard's node needs
  the network and disk throughput for its share.
- **Blast radius.** Losing a shard's data costs `1/N` of the cache. An
  unavailable shard is worse: `FindMissingBlobs` fails if any shard is down, so
  uploads stop cluster-wide. See
  [Sharding and the Frontend Path](buildbarn-storage-model.md#sharding-and-the-frontend-path).

Grow by adding shards. Rendezvous hashing moves only about `1/N` of the keys
when a shard is added; see
[Scale Storage Shards](buildbarn-storage-operations.md#scale-storage-shards).

### Network disks or local NVMe

| | Network disks (PVC) | Local NVMe (LVM on the node) |
| --- | --- | --- |
| Survives node replacement | Yes; the disk reattaches to the new node | No; a replaced node starts with an empty shard |
| Survives pod restart | Yes, with file-backed indexes | Yes, with file-backed indexes on the same NVMe |
| Disk traffic | Shares the node's network on most clouds; per-volume IOPS and throughput caps scale with size and tier | Stays on the node, leaving the network for serving reads |
| Cost per TB | Higher | Lower; the drive comes with the node |
| Setup | StorageClass only | A provisioning DaemonSet and a dedicated node pool; see [Local NVMe SSD](buildbarn-block-storage.md#gke-example-b-local-nvme-ssd-with-partition_ephemeral_disks) |

Choose local NVMe when read throughput is high or network disks are the
bottleneck, and plan for node replacement:

- **Know what replaces nodes.** On GKE, node-pool upgrades and auto-repair create
  new VMs, so each one empties a shard. Compute Engine host maintenance usually
  live-migrates the VM with its local SSD data. Other clouds lose local drives on
  instance termination and some maintenance events.
- **Control upgrades.** Use a fixed-size, non-spot pool. On GKE, a maintenance
  exclusion with scope `no_minor_or_node_upgrades` stops automatic node upgrades,
  and a maintenance window bounds when they run. Upgrade the storage pool by hand,
  one node at a time, and let each shard refill before the next.
- **Keep indexes with the data.** Put the key-location map files on the same
  local drive as the blocks, so a restart keeps the cache and a lost drive takes
  both. Never keep indexes on a network disk over local blocks.

### Storage pod memory

The key-location maps are memory-mapped and probed at random, so their working
set should stay in page cache. Budget at least the total size of all index files
plus about 6 GiB for the Go heap and buffers. Size the maps themselves from
[The Key-Location Map](buildbarn-storage-model.md#the-key-location-map) and
turn on `storage.keyLocationMapSizing.validate` so an undersized map fails the
render instead of losing blobs.

## Buildbarn frontend, scheduler and workers

- **Frontend replicas.** Size from the cache request rate, including
  `FindMissingBlobs`. Let KEDA scale on CPU and in-flight calls, with a minimum
  that carries your normal daytime load; see
  [Frontend autoscaling](../charts/buildbarn/README.md#frontend-autoscaling).
- **Frontend read cache.** It serves repeated reads from Bazel clients. Workers
  bypass it, so it does not carry executor reads, and a fast boot volume is
  usually enough. Size it against the client read working set; see
  [The Frontend Read-Through Cache](buildbarn-storage-model.md#the-frontend-read-through-cache).
- **Worker pools.** One pool, or a pair of size classes, per platform. Maximum
  replicas are peak concurrent actions divided by slots per worker. Each worker
  keeps a local cache of input blobs, which absorbs repeated inputs before they
  reach the shards, so give workers fast local disk; see
  [Worker Local Cache and Volume Sizing](buildbarn-storage-model.md#worker-local-cache-and-volume-sizing)
  and [KEDA Autoscaling](../charts/bb-worker-operator/README.md#keda-autoscaling).
- **Scheduler.** It runs as one replica, so give it room to grow with
  concurrency: about 2–4 CPU and 4–8 GiB of memory for several thousand
  concurrent actions.

## Hermetiq ingest and database

- **Stream partitions.** Choose `app.streamPartitionCount` before production
  traffic starts; changing it later changes the stream and subscriber topology.
  Start from the tiers in
  [Large-scale deployments](../charts/hermetiq/README.md#large-scale-deployments-and-high-throughput-ingest).
  With replicated (R3) streams, pick a count whose replicas divide evenly across
  your NATS servers: on 5 servers, 10 partitions give 30 replicas, 6 per server.
  Set Buildbarn's `frontend.grpcCacheProxy.cacheEvents.numShards` to the same
  number.
- **NATS.** Run 3 or 5 servers. Each partition's cache-event stream reserves
  128 MiB of JetStream memory, and the file store should buffer about 30 minutes
  of events while PostgreSQL is busy.
- **PostgreSQL size.** A 16 vCPU, 64 GiB instance with 10,000 or more write IOPS
  handles more than 500,000 builds a day when build logs are in object storage.
  Set `max_connections` to cover every subscriber, publisher and API pool, about
  300–500 at scale. A read replica is optional and can be added later.
- **Partition interval.** Pick `bootstrap.partitionInterval` so each partition
  holds tens of thousands of invocations and the active partition's indexes stay
  in memory: `6 hour` suits most installations, `4 hour` suits several hundred
  thousand invocations a day. There are 15 partitioned tables, so the number of
  child tables is `15 × partitions per day × retention days`, plus premade ones.
  When that reaches a few thousand, raise `max_locks_per_transaction` to 256–512.
  The interval cannot change after the first install; see
  [Partition policy](../charts/hermetiq/README.md#partition-policy).
- **Build logs.** Store them in object storage (Google Cloud Storage, Azure Blob,
  or S3-compatible). In PostgreSQL they are most of the write load at high
  volume; see [Progress log storage](../charts/hermetiq/README.md#progress-log-storage).
- **Action Cache Hit Tracker.** It writes one record per cache hit. At thousands
  of hits a second it becomes the largest table, so size PostgreSQL for it before
  turning it on.

## Worked examples

### A large CI fleet

| Workload | Value |
| --- | --- |
| Invocations | ~400,000 a day |
| Cache uploads | ~1.5 TB a day |
| Executor input reads | ~800 MB/s on average |
| Cache requests | ~8,000 per second (AC and CAS) |
| Concurrent remote actions | ~4,000 amd64 and ~1,000 arm64 on average |

| Decision | Starting value | Reasoning |
| --- | --- | --- |
| Storage | 12 shards on nodes with one 6.8 TB local NVMe drive each | ~75 TB usable, about 50 days of uploads. Executor reads come to ~67 MB/s per shard and stay off the network. |
| Network-disk alternative | 15 shards of 1500Gi PVCs | ~19.5 TB usable, about 13 days; reads of ~53 MB/s per shard over the network |
| Frontend | 6 to 30 replicas | Cache request rate |
| Workers | An amd64 and an arm64 pool, each with two size classes | Average concurrency from remote execution minutes; maximums at about three times that |
| Stream partitions | 10, on 5 NATS servers | Even R3 placement; ~40,000 invocations a day per partition |
| PostgreSQL | 16 vCPU, 64 GiB, `4 hour` partitions, 30-day retention | ~67,000 invocations per partition; build logs in object storage |

### A lightly loaded cluster

Three 1 TiB shards on network disks hold about 2.85 TB usable. Eviction age is
42 hours, so the store writes about 1.6 TB a day. Moving to three local-NVMe
nodes:

| Drive per node | Usable per shard | Untouched data lasts | Old stretch at `8/30/3` | At `12/26/3` |
| --- | --- | --- | --- | --- |
| 1.5 TB | ~1.33 TB | ~2.5 days | ~12 hours | ~18 hours |
| 3 TB | ~2.7 TB | ~5 days | ~23 hours | ~35 hours |

With 3 TB drives and `12/26/3`, anything used at least once a day stays cached
indefinitely.

## After go-live

Two weeks after go-live, check:

- **Eviction age** per shard against your retention target. The chart's
  `BuildbarnCacheRetentionLow` alert fires below 24 hours.
- **Key-location-map alerts** `BuildbarnKeyLocationMapPutsDropped` and
  `BuildbarnKeyLocationMapGetsExhausted` stay quiet.
- **Action Cache hits that fail the completeness check**, which mean the CAS
  evicts outputs before the Action Cache drops their results.
- **CMS eviction age** stays at or above CS eviction age.
- **NATS stream placement** is even across servers (`nats stream report`).
- **PostgreSQL** connections, IOPS, and rows in the `_default` partitions.

If retention is short, add shards rather than resizing existing ones; see
[Changes That Flush the Cache](buildbarn-storage-operations.md#changes-that-flush-the-cache).
