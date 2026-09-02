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

The key-location map defaults to memory:

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

A practical split is:

- CAS: 97%
- AC: 1%
- ISCC: 1%, when enabled
- FSAC: 1%, when enabled

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

If you set `keyLocationMap: file` on local SSD, place the metadata on the same local SSD with `blockDevice.metadata.hostPath.path`. Do not put raw local blocks beside metadata on a network PVC. Losing either the blocks or metadata empties the store, so splitting them across durability tiers makes recovery behavior harder to reason about.

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
