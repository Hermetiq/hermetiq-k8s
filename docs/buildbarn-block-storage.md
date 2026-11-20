# Buildbarn Raw Block-Device Storage on GKE

By default, each Buildbarn storage shard keeps CAS and Action Cache blocks in files on a filesystem volume. CAS remains the logical content-addressable store: CDC changes its physical chunk layout, and CMS records how chunks compose a blob. Filesystem-backed storage is the simplest mode and suits many deployments.

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

Use this for a node-local tier that retains warmed contents and learned history
across storage pod restarts. The supplied LVM DaemonSet places raw data LVs and
a metadata filesystem on the **same Local SSDs**. This makes process persistence
useful without treating ephemeral SSDs as durable storage: replacement or loss of
those SSDs still requires a cold store.

Use the two files together:

- [partition-ephemeral-disks-daemonset.yaml](../custom-values/partition-ephemeral-disks-daemonset.yaml) prepares and verifies the node storage before labelling it `hermetiq/ephemeral-lvm=ready`.
- [buildbarn-values-local-ssd-block.yaml](../custom-values/buildbarn-values-local-ssd-block.yaml) selects persistent indexes for all five stores and points metadata hostPaths at the verified SSD mount.

Apply the DaemonSet first, then layer the overlay after your base values. Both
the provisioner and hostPath storage containers require a namespace that permits
privileged pods. Follow the [GKE validation runbook](buildbarn-gke-storage-validation.md)
when changing the node image, provisioning script, or disk layout.

### Layout and readiness

The DaemonSet targets `node-type=ssd-block` nodes created with
`--local-nvme-ssd-block`. It discovers and stripes every raw Local SSD into the
`ephemeral` VG. Fresh nodes receive these LVs, in order:

| LV | Size | Purpose |
|---|---|---|
| `meta` | 16 GiB | ext4 filesystem for indexes, checkpoints, and shared CMS |
| `ac` | 8 GiB | AC raw blocks |
| `iscc` | 2 GiB | ISCC raw blocks |
| `fsac` | 6 GiB | FSAC raw blocks |
| `cas` | all remaining extents | CAS raw blocks; about 718 GiB with two GKE "375GB" SSDs exposing 375 GiB each |

`/dev/ephemeral/meta` is mounted at
`/mnt/stateful_partition/buildbarn-local-ssd/metadata`. The parent directory is
on COS's writable stateful partition, but **the mounted metadata filesystem is
on Local SSD**, not the boot disk. A privileged init container uses the host PID
and mount namespaces to make only this dedicated parent a shared mount; COS
does not provide that property by default. Bidirectional propagation then makes
the metadata submount visible to hostPath volumes in storage pods. The per-store directories
`cas`, `ac`, `iscc`, and `fsac` use ownership `65534:65534` and mode `0770`.
Shared CMS lives below the CAS metadata directory; it has no separate raw LV.
The configured index files total about 9.75 GiB, plus 1 GiB of shared CMS blocks,
leaving filesystem and checkpoint headroom within the 16 GiB LV.

On startup the provisioner clears `hermetiq/ephemeral-lvm`, verifies the layout,
and activates existing LVs because COS has no host LVM activation service. It
privately mounts metadata at `/tmp/buildbarn-metadata-staging` if needed and
verifies the exact ext4
mountpoint, its filesystem UUID, writable mount options, directory permissions,
and `.buildbarn-layout-v1`. That marker records the VG, LV, and filesystem UUIDs
so checkpoints cannot silently attach to a recreated data LV. Only after these
checks does it publish the verified filesystem at the host metadata path and
label the node ready. The same checks run periodically and in its readiness probe;
a detected mismatch removes the scheduling label and fails the provisioner.

The storage overlay requires the ready label and uses `type: Directory` for
metadata hostPaths. A missing per-store directory therefore fails mounting
instead of being silently created on the boot disk. Staging before publication
also keeps those directories unavailable to an already-bound pod restarting
during node boot until the metadata generation has been checked.
**The label gates scheduling; it does not evict an already running storage pod.** Stop affected storage before
repairing a missing mount or a generation mismatch, and verify it again before
allowing requests. UUID checks detect recreation, not arbitrary in-place zeroing
or corruption of an LV.

The script formats metadata only when creating a completely new VG. Restarting
the provisioner remounts existing metadata and verifies its marker; it never
formats an existing metadata LV or changes data-LV sizes. A partially created
layout, missing marker, or old full VG without `meta` fails closed and needs an
operator-reviewed cold cut-over. Changing size values does not resize existing
LVs.

Implementation details:

- The manifest uses `alpine:3.20` with `lvm2`, `curl`, `e2fsprogs`, and `util-linux`. For restricted-egress clusters, bake those packages into an image first.
- It uses classic LVM striping through `dm-mod`. LVM `--type raid0` requires `dm-raid`, which the target GKE COS image cannot load.
- Its `terminationMessagePath` is outside `/dev` because it bind-mounts the host's `/dev`.
- Its ServiceAccount can `get` and `patch` Nodes to manage the scheduling label.

### Cold cut-over and failure recovery

Existing layouts that allocated the entire VG to four data LVs cannot gain the
16 GiB metadata LV in place. Use a fresh storage node pool or explicitly reset a
drained shard's **whole** VG. Do not shrink CAS or recreate one data LV while
retaining its old metadata. The CDC upgrade already requires a cold format
cut-over; combine the two planned outages when upgrading from pre-CDC storage.

Drain builds and stop the affected storage processes before replacing devices or
resetting a VG. Recreate blocks and metadata together, wait for the verified
ready label, and start storage with the persistent overlay. Check that old keys
are missing and clean uploads/readback succeed. Restart frontends before resuming
clients so positive existence-cache entries do not refer to the discarded data.
Restore rollback state only as a consistent blocks-and-metadata pair taken with
storage stopped; retained metadata alone is not a rollback copy.

**Never put persistent metadata on the boot disk or a network PVC while blocks
live on Local SSD.** A normal guest-OS reboot preserves Local SSD contents, but a
host-recovery failure can return the same VM with blank SSDs and an intact boot
disk. Surviving metadata can then advertise nonexistent blobs as present. See
Google's [Local SSD persistence and recovery behavior](https://cloud.google.com/compute/docs/disks/local-ssd#data_persistence).

If a storage pod stays Pending, inspect the provisioner on its intended node:

```bash
kubectl -n hermetiq logs ds/partition-ephemeral-disks
kubectl get nodes -l node-type=ssd-block -L hermetiq/ephemeral-lvm
```

No raw SSDs usually means the node pool was created without
`--local-nvme-ssd-block`, or used `--ephemeral-storage-local-ssd` instead. A legacy
VG, missing metadata mount, wrong filesystem, or generation mismatch is an
intentional refusal to serve; resolve the paired storage lifecycle rather than
manually adding the ready label.

For intentionally volatile indexes, apply
[buildbarn-values-ephemeral.yaml](../custom-values/buildbarn-values-ephemeral.yaml)
**after** this overlay. That discards cache/training state on each storage-process
restart and does not remove the need to handle frontend existence-cache entries
after a cold reset. Keep every enabled store on its intended Local SSD layout;
a filesystem hostPath outside the metadata mount can otherwise use the boot disk.

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
