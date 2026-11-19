# Buildbarn Raw Block-Device Storage on GKE

By default, each Buildbarn storage shard keeps CAS and Action Cache blocks in files on a filesystem volume. That is the simplest mode, and it is the right default for many deployments.

Raw block-device storage is the lower-overhead option. Instead of writing a large blocks file on a mounted filesystem, a store writes directly to a Kubernetes `volumeMode: Block` device. In chart values, set the store's `backend: blockDevice`.

Use it when one of these tradeoffs fits:

- persistent, network-attached block storage with less filesystem overhead
- fast local SSD cache tiers where losing a node only means colder builds
- dynamically carved LVM block volumes, such as TopoLVM

Raw block storage changes the plumbing, not the storage model. Block geometry, the maximum blob size, and key-location-map sizing still follow [buildbarn-storage-model.md](buildbarn-storage-model.md). Restart and resize behavior is covered in [buildbarn-storage-operations.md](buildbarn-storage-operations.md).

## What the Chart Creates

For each raw block store, the chart creates a dedicated blocks claim named `<store>-blocks`. The device appears in the pod at `/dev/bb/<store>`.

The whole device becomes the block store. Buildbarn derives the block size from the device size and block counts, so `blocksSizeGi` is ignored in `backend: blockDevice` mode. For PVC-backed raw block storage, `blockDevice.size` is the PVC request. For hostPath raw block storage, the device size comes from the host device.

The raw-block key-location map defaults to memory for CS, AC, ISCC, FSAC, and a
dedicated raw CMS. These
defaults remain unchanged unless you explicitly select `file` or apply the
[persistent profile](buildbarn-storage-operations.md#migrate-to-persistent-indexes):

```yaml
storage:
  persistence:
    mode: pvc
    cas:
      backend: blockDevice
      blockDevice:
        storageClassName: bb-block-hyperdisk
        size: 1000Gi
        keyLocationMap: inMemory
        keyLocationMapInMemoryEntries: 20000000
```

That is simple and fast, but it is cache-only. A storage-pod restart empties the store because the bytes no longer have an index. To make a raw block store persistent across restarts, use:

```yaml
keyLocationMap: file
```

The chart then creates a small companion filesystem PVC named `<store>-meta` for the KLM file and `persistent_state` directory. Treat that metadata claim as part of the store. If either the metadata claim or the blocks claim is lost, the store starts empty.

CMS defaults to `backend: sharedCas`, so it does not need its own raw device or
PVC. With a file-backed raw CAS index, shared CMS uses the CAS metadata volume
for its blocks, index, and checkpoint state under `cdc-v1/`. Budget an additional
`1 GiB` for CMS blocks and `256 MiB` for its index at the default sizes, plus
filesystem/state headroom. With an in-memory raw CAS index, shared CMS keeps its
blocks and index in memory too. Losing CMS makes composite CAS blobs unreadable
even when their chunks survive.

## Device Access and Pod Security

The storage container runs as uid/gid 65534. It needs permission to open the block device. Kubernetes handles this differently depending on how the device is attached.

### PVC-Backed Block Devices

With `storage.persistence.mode: pvc`, the block device is attached with `volumeDevices`. The storage container can stay non-privileged.

`storage.persistence.blockDevice.deviceAccess` controls how the node device file is made accessible:

- `group` is the default. It is compatible with Pod Security Standards restricted mode, but only works if the CSI driver presents the device with useful group permissions. The GKE Persistent Disk CSI driver presents devices as `root:root`, so verify this on your driver before relying on it.
- `chownInit` runs a small root init container that fixes ownership. It needs `CHOWN`, `FOWNER`, and `DAC_OVERRIDE`, so the namespace needs baseline permissions or a Pod Security Admission exemption.

### HostPath Block Devices

With `storage.persistence.mode: hostPath` and `blockDevice.allowHostPath: true`, Kubernetes cannot use `volumeDevices` because the source is a hostPath device. The chart bind-mounts the device and runs the storage container with `privileged: true`.

There is no non-privileged hostPath-block path in this chart. Plan for a baseline or privileged namespace.

## Switching an Existing Release

Switching a live release from filesystem storage to raw block storage creates new empty volumes. There is no data migration.

StatefulSet `volumeClaimTemplates` are effectively immutable, and Kubernetes retains StatefulSet PVCs. Raw block mode also uses different claim names (`<store>-blocks` and `<store>-meta` instead of the old filesystem claims). After the new storage pods are healthy, delete the old `cas` and `ac` claims manually so they stop billing.

Helm cannot patch the volume claim templates in place. Plan a reviewed StatefulSet recreate.

If this change also upgrades a pre-CDC release, follow the
[storage-format cutover](buildbarn-storage-model.md#storage-format-cutover-and-rollback)
before starting the new storage image. That migration stops clients and storage
and resets all pre-CDC stores, including persisted ISCC/FSAC. Adding disk-backed
indexes does not convert the old encoding or preserve the old history through
that format change.

## GKE Example A: Persistent Disk or Hyperdisk

Use this when you want durable, network-attached storage. The GKE Persistent Disk CSI driver supports `volumeMode: Block` directly, so no DaemonSet is needed.

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: bb-block-hyperdisk
provisioner: pd.csi.storage.gke.io
parameters:
  type: hyperdisk-balanced # or pd-ssd
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Retain
allowVolumeExpansion: true
```

`hyperdisk-balanced` and `pd-ssd` are zonal. `WaitForFirstConsumer` binds each replica in the zone where its pod lands. A shard survives pod restart and reschedule within that zone, but not a full-zone loss. Use regional disks if you need cross-zone disk availability.

Example values:

```yaml
storage:
  persistence:
    mode: pvc
    cas:
      backend: blockDevice
      blockDevice:
        storageClassName: bb-block-hyperdisk
        size: 1000Gi
        keyLocationMap: file
```

Use `keyLocationMap: file` for persistence, or `inMemory` when the disk is only being used as a cache tier.

## GKE Example B: Local NVMe SSD with `partition_ephemeral_disks`

Use this for the fastest cache-only tier. Buildbarn's `partition_ephemeral_disks` tool runs as a DaemonSet, stripes a node's local NVMe SSDs into an LVM2 volume group named `ephemeral`, and carves logical volumes for the stores.

This repository includes a ready-to-edit version of that pattern:

- `custom-values/partition-ephemeral-disks-daemonset.yaml` prepares the node devices and labels nodes `hermetiq/ephemeral-lvm=ready`.
- `custom-values/buildbarn-values-local-ssd-block.yaml` consumes those devices as a Helm values overlay.

Apply the DaemonSet first, then layer the overlay after your base
`buildbarn-values.yaml`.

### How the DaemonSet works

`partition-ephemeral-disks-daemonset.yaml` runs one privileged pod per
`node-type=ssd-block` node. On start it:

1. Clears the node label `hermetiq/ephemeral-lvm`, so a node whose SSDs were
   wiped by a reboot is not advertised as ready with stale state.
2. Finds the raw Local SSDs at `/dev/disk/by-id/google-local-nvme-ssd-*` and
   refuses to run if there are none, which means the node pool was not created
   with `--local-nvme-ssd-block`.
3. Creates the LVM2 volume group `ephemeral` across all of them, once.
4. Creates the logical volumes if they do not exist, striped across every SSD:
   `ac` 8 GiB, `iscc` 2 GiB, `fsac` 6 GiB, then `cas` with all remaining
   extents. The small stores use fixed sizes rather than percentages because
   they hold tiny objects (about 1.1 KiB ActionResults, 0.5 KiB ISCC records,
   2 KiB FSAC bloom filters). A percentage of a multi-SSD node would hand them
   tens of GiB and millions of extra key-location-map slots that the values
   file would then have to cover in RAM. Fixed sizes keep the sizing arithmetic
   in `buildbarn-values-local-ssd-block.yaml` valid on any node shape.
5. Verifies that all four block devices exist, labels the node
   `hermetiq/ephemeral-lvm=ready`, and sleeps. The storage overlay's
   `nodeSelector` requires that label, so storage pods stay Pending until the
   devices exist instead of failing to mount.

Every step is idempotent, so a restarted DaemonSet pod is harmless. `lvcreate`
is guarded by `lvs`, so editing a size never resizes an existing volume; only
fresh or wiped nodes pick the change up.

Implementation notes:

- It does not use `ghcr.io/buildbarn/bb-partition-ephemeral-disks`. That image
  is built on `distroless_static` and shells out to `vgcreate` and `lvcreate`,
  which are not present there. The DaemonSet runs the same LVM2 commands from
  `alpine:3.20` after `apk add lvm2 curl`. For air-gapped clusters, bake an
  image with those packages and set `image:`.
- Volumes are striped with classic LVM striping (the device-mapper `striped`
  target in the already loaded `dm-mod`) rather than `--type raid0`, which
  needs the `dm-raid` module that GKE Container-Optimized OS cannot load.
- `terminationMessagePath` is moved off `/dev` because the container
  bind-mounts the host `/dev`. The kubelet's default termination-log mount
  otherwise races the hostPath mount and `runc` fails before the process starts.
- Node labels are cluster-scoped, so the pod's ServiceAccount has a ClusterRole
  limited to `get` and `patch` on Nodes.

Troubleshooting:

- A storage pod stays Pending and no node carries `hermetiq/ephemeral-lvm=ready`:
  read `kubectl -n hermetiq logs ds/partition-ephemeral-disks` for that node.
- `ERROR: no /dev/disk/by-id/google-local-nvme-ssd-* devices`: the node pool
  was created with `--ephemeral-storage-local-ssd` or without local SSDs.
- To change a logical volume size, recreate the node (or run `vgremove
  ephemeral` on it after draining). The store on that shard comes back empty.

Storage pods then consume the logical volumes as hostPath block devices:

```yaml
storage:
  # Use a raw-block Local SSD node pool, for example one created with
  # gcloud --local-nvme-ssd-block. Do not target the
  # cloud.google.com/gke-ephemeral-storage-local-ssd label; that mode formats
  # and mounts the SSDs as a filesystem, leaving no raw device to partition.
  # Storage shards should not be preemptible.
  nodeSelector:
    node-type: ssd-block
    hermetiq/ephemeral-lvm: ready
  persistence:
    mode: hostPath
    blockDevice:
      allowHostPath: true
      deviceAccess: chownInit
    cas:
      backend: blockDevice
      blockDevice:
        keyLocationMap: inMemory
        hostPath:
          devicePath: /dev/ephemeral/cas
    ac:
      backend: blockDevice
      blockDevice:
        keyLocationMap: inMemory
        hostPath:
          devicePath: /dev/ephemeral/ac
```

> **Configure every enabled store.** If `mode: hostPath` is set and a store is left on `backend: filesystem`, the chart falls back to the default hostPath directory with `type: DirectoryOrCreate`. On a raw-block Local SSD node pool, nothing is mounted there, so Kubernetes creates the directory on the node boot disk. Configure `ac`, and `iscc`/`fsac` when enabled, on their own logical volumes.

This path is cache-only by design. A node loss drops that shard, and builds refill it. The storage container is privileged, and the partitioning DaemonSet is privileged too, so use a namespace that permits that model.

For `keyLocationMap: file`, explicitly choose a retained filesystem directory with
`blockDevice.metadata.hostPath.path`. A filesystem on Local SSD works; for the
small ISCC map, the [ISCC-only example](iscc-size-classes.md#1-enable-iscc-storage)
uses the node boot filesystem at `/mnt/stateful_partition/buildbarn-storage/iscc-meta`.
Reserve at least 1 GiB there for the 512 MiB map and state-file headroom;
`metadata.size` does not enforce
a hostPath quota. This protects same-node pod restarts only. Losing either the
blocks or metadata empties the store, and durable metadata alone cannot rescue
blocks lost with a Local SSD node. Node replacement requires durable storage for
both pieces; see the [ISCC guide](iscc-size-classes.md#1-enable-iscc-storage).

When applying the persistent profile to all four raw devices, provide a metadata
directory for each one and include shared CMS capacity in the CAS directory.
The profile changes index modes without resizing their configured files; CAS's
default `7360 MiB` index plus shared CMS's `1280 MiB` files already require
`8640 MiB` before filesystem and checkpoint headroom.

## GKE Example C: TopoLVM CSI

[TopoLVM](https://github.com/topolvm/topolvm) dynamically carves an LVM volume group into logical volumes and provisions them as `volumeMode: Block` PVCs. This gives you local-SSD-style block devices while keeping the storage container non-privileged, because Kubernetes attaches them through `volumeDevices`.

TopoLVM replaces the hostPath device mount and the Buildbarn partitioning DaemonSet. You still need a one-time way to create the LVM volume group on the raw-block Local SSD nodes, such as a node startup script or a small `vgcreate` DaemonSet. TopoLVM's `lvmd` manages logical volumes inside an existing volume group; it does not create the volume group for you.

Create a block StorageClass:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: topolvm-ssd
provisioner: topolvm.io
parameters:
  "topolvm.io/device-class": "ephemeral"
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
```

Then consume it through ordinary PVC raw block storage:

```yaml
storage:
  nodeSelector:
    node-type: ssd-block
  persistence:
    mode: pvc
    cas:
      backend: blockDevice
      blockDevice:
        storageClassName: topolvm-ssd
        size: 700Gi
        keyLocationMap: inMemory
    ac:
      backend: blockDevice
      blockDevice:
        storageClassName: topolvm-ssd
        size: 8Gi
    iscc:
      enabled: true
      backend: blockDevice
      blockDevice:
        storageClassName: topolvm-ssd
        size: 8Gi
    fsac:
      enabled: true
      backend: blockDevice
      blockDevice:
        storageClassName: topolvm-ssd
        size: 8Gi
```

Unlike hostPath mode, `blockDevice.size` matters here because it is the PVC request and therefore the logical volume size TopoLVM carves for each replica.

Device ownership uses the same `deviceAccess` choices as the Persistent Disk example: try `group` only if your CSI driver presents group-accessible devices, otherwise use `chownInit`. The long-lived storage container remains non-privileged, which is the main operational advantage over the hostPath local SSD path.
