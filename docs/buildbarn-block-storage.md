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

The raw-block key-location map defaults to `file` for CS, AC, ISCC, FSAC, and a
dedicated raw CMS. Both PVC-backed devices and local NVMe use persistent indexes:

```yaml
storage:
  persistence:
    mode: pvc
    cas:
      backend: blockDevice
      blockDevice:
        storageClassName: bb-block-hyperdisk
        size: 1000Gi
        keyLocationMap: file # default
```

The chart creates a companion filesystem PVC named `<store>-meta` for the KLM
file and `persistent_state` directory. Treat that metadata claim as part of the
store. Losing metadata requires a cold reset. Losing or replacing blocks while
retaining metadata is worse: the index can report nonexistent blobs as present,
so clients skip uploads and reads fail. Reset blocks and metadata as one unit. In
`mode: hostPath`, instead supply each store's `blockDevice.metadata.hostPath.path`;
Helm rejects a missing path rather than choosing a filesystem for you.

For intentionally volatile storage, set `keyLocationMap: inMemory` or apply the
[ephemeral profile](buildbarn-storage-operations.md#explicit-ephemeral-opt-out).
That removes metadata volumes for raw stores and starts them empty after every
storage-process restart. Review the migration before removing metadata claims
from an existing PVC deployment.

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

`keyLocationMap: file` is the default. Select `inMemory` only when losing this
store on each process restart is intentional.

## GKE Example B: Local NVMe SSD with `partition_ephemeral_disks`

Use this for an explicitly volatile node-local tier. The supplied overlay uses in-memory indexes, so every storage-process restart starts cold. Buildbarn's `partition_ephemeral_disks` tool runs as a DaemonSet, stripes a node's local NVMe SSDs into an LVM2 volume group named `ephemeral`, and carves logical volumes for the stores.

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

Storage pods consume the logical volumes using the complete
[local SSD overlay](../custom-values/buildbarn-values-local-ssd-block.yaml).
It explicitly sets `blockDevice.keyLocationMap: inMemory` on CAS, AC, ISCC, and
FSAC; shared CMS is also in memory. This overrides the chart's persistent
defaults because the bundled provisioner creates raw LVs only. It does not
create a metadata filesystem that is lost/reset with those LVs.

**Do not place persistent metadata on the boot disk or a network PVC while
blocks live on Local SSD.** A host failure can return the same VM with blank
SSDs while boot-disk metadata survives. The index can then report missing blobs
as present. Google documents this [Local SSD recovery behavior](https://cloud.google.com/compute/docs/disks/local-ssd#data_persistence).

To make this layout persistent, first provision a metadata filesystem on the
**same Local SSD storage** as the raw LVs and validate the mount/reset lifecycle
on the actual node pool. Reserve space for all indexes, shared CMS blocks, and
checkpoint state; the current sizes need about 10.75GiB before headroom (plan
at least 16GiB). Gate storage scheduling on the verified mount. Use `Directory`
for metadata hostPaths so a missing mount directory cannot silently be created
on the boot disk. Reset all paired indexes/checkpoints when devices or the VG
are recreated. The current DaemonSet neither provisions nor validates this
layout; do not append the persistent profile to the supplied overlay without
completing that work.

> **Configure every enabled store.** On raw-block Local SSD nodes, filesystem
> hostPaths can otherwise land on the boot disk. Keep enabled AC/ISCC/FSAC on
> their configured LVs and explicitly select their intended index mode.

The volatile fallback is intentional until a same-SSD metadata layout is tested
on GKE. It avoids stale persistent indexes but loses warmed contents and learned
history on restart. Drain builds and restart frontends during planned resets to
clear positive existence-cache entries. The storage and provisioner containers
remain privileged, so use a namespace that permits that model.

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
        metadata:
          storageClassName: topolvm-ssd
        size: 700Gi
        keyLocationMap: file
    ac:
      backend: blockDevice
      blockDevice:
        storageClassName: topolvm-ssd
        metadata:
          storageClassName: topolvm-ssd
        size: 8Gi
    iscc:
      enabled: true
      backend: blockDevice
      blockDevice:
        storageClassName: topolvm-ssd
        metadata:
          storageClassName: topolvm-ssd
        size: 2Gi
    fsac:
      enabled: true
      backend: blockDevice
      blockDevice:
        storageClassName: topolvm-ssd
        metadata:
          storageClassName: topolvm-ssd
        size: 6Gi
```

Use the filesystem-capable `topolvm-ssd` class for every companion metadata
PVC, as shown above, so it uses the same local device class as its blocks.
The persistent default requires this companion volume; the network
`premium-rwo` chart default is unsuitable for this local-storage example.

Unlike hostPath mode, `blockDevice.size` matters here because it is the PVC request and therefore the logical volume size TopoLVM carves for each replica.

Device ownership uses the same `deviceAccess` choices as the Persistent Disk example: try `group` only if your CSI driver presents group-accessible devices, otherwise use `chownInit`. The long-lived storage container remains non-privileged, which is the main operational advantage over the hostPath local SSD path.

Keep each blocks PVC and metadata PVC on the same local StorageClass/device
class. Never pair these local blocks with the default network `premium-rwo`
metadata claim. Co-location does not make an independent PVC reset safe: after
loss/recreation of either member, stop the shard and reset/delete the matching
`<store>-blocks` and `<store>-meta` claims together. Restore rollback snapshots
only as a consistent pair. Shared CMS is part of the CAS metadata claim.
