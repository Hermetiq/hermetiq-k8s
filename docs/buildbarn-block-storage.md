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
        metadata:
          storageClassName: bb-block-hyperdisk
        size: 1000Gi
        keyLocationMap: file # default
```

The chart creates a companion filesystem PVC named `<store>-meta` for the KLM
file and `persistent_state` directory. Treat that metadata claim as part of the
store. Losing metadata requires a cold reset. Losing or replacing blocks while
retaining metadata is worse: the index can report nonexistent blobs as present,
so clients skip uploads and reads fail. Reset blocks and metadata as one unit.

The metadata claim has its own StorageClass,
`blockDevice.metadata.storageClassName`, and it defaults to `premium-rwo` for
every store whatever class the blocks use. Set it for every raw store, as above,
to a class whose volumes are lost together with the blocks. On install or
upgrade the Helm notes print `WARNING: STORAGE CLASS MISMATCH` for each raw
store whose blocks and metadata classes differ, and for each filesystem store
whose `storageClassName` differs from the CAS class; nothing fails the render.
A claim keeps the class and size it was created with: a changed value only
applies to claims that do not exist yet. To move existing metadata to another
class, stop storage, delete that `<store>-meta-storage-<i>` claim and reset the
matching blocks in the same step.

In `mode: hostPath` there are no claims. Supply each store's
`blockDevice.metadata.hostPath.path`; Helm rejects a missing path rather than
choosing a filesystem for you. The directory must already exist on the node, on
the same storage as the blocks: `blockDevice.metadata.hostPath.type` defaults
to `Directory` (it was `DirectoryOrCreate` before chart 0.10.0), so a missing
directory fails the volume mount and the pod does not start. Do not override it
with `DirectoryOrCreate`, which lets the kubelet create the directory on the
boot disk when the metadata filesystem is not mounted. Point the path at a
directory inside the mounted filesystem, not at the mountpoint itself: the
mountpoint exists on the boot disk whether or not anything is mounted.

For intentionally volatile storage, set `keyLocationMap: inMemory` or apply the
[ephemeral profile](buildbarn-storage-operations.md#explicit-ephemeral-opt-out).
That removes metadata volumes for raw stores and starts them empty after every
storage-process restart. Review the migration before removing metadata claims
from an existing PVC deployment. The profile sets no RAM entry counts: a raw
store larger than the chart default device (200Gi for CAS) needs an explicit
`blockDevice.keyLocationMapInMemoryEntries`, and the profile's header gives the
formula.

CMS defaults to `backend: sharedCas`, so it does not need its own raw device or
PVC. With a file-backed raw CAS index, shared CMS uses the CAS metadata volume
for its blocks, index, and checkpoint state under `cdc-v1/`. At the default
sizes that is `1 GiB` of CMS blocks and a `1280 MiB` index (`2304 MiB`) beside
the `7360 MiB` CAS index: `9664 MiB` of files, which the default `10Gi` CAS
metadata claim holds. Raise `cas.blockDevice.metadata.size` before raising any
of the three. With an in-memory raw CAS index, shared CMS keeps its blocks and
index in memory too. Losing CMS makes composite CAS blobs unreadable even when
their chunks survive.

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

Helm cannot patch the volume claim templates in place. Plan a reviewed StatefulSet recreate. On `helm install` or `helm upgrade` the chart compares the live `storage` StatefulSet's claim templates with the rendered ones and, when they differ, fails before anything is applied and lists the differences; follow [Recreate the Storage StatefulSet](buildbarn-storage-operations.md#recreate-the-storage-statefulset). `helm template`, GitOps renders and `helm rollback` do not run that check.

A release whose raw PVC stores ran in-memory indexes on 0.9.9 (the raw default then) has no `<store>-meta` claims. Chart 0.10.0 defaults those stores to file indexes and adds a `<store>-meta` template for each, on `premium-rwo` unless you set `blockDevice.metadata.storageClassName`. Either set that class for every raw store and recreate the StatefulSet, or keep the indexes volatile by applying the [ephemeral profile](buildbarn-storage-operations.md#explicit-ephemeral-opt-out) last: with it the raw stores render the same claim templates as on 0.9.9. ISCC and FSAC are now enabled by default and add their own claims unless the release already had them or sets `enabled: false`.

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
        metadata:
          storageClassName: bb-block-hyperdisk
        size: 1000Gi
        keyLocationMap: file
```

`keyLocationMap: file` is the default. Select `inMemory` only when losing this
store on each process restart is intentional.

This renders `cas-blocks` (Block, `1000Gi`) and `cas-meta` (Filesystem, `10Gi`)
on `bb-block-hyperdisk`. Without the `metadata.storageClassName` line the
metadata claim lands on the chart default `premium-rwo`. AC, ISCC and FSAC stay
filesystem stores on their own `storageClassName` (also `premium-rwo` by
default), and the Helm notes report each of them as a class mismatch against
CAS until you set the same class there.

## GKE Example B: Local NVMe SSD with `partition_ephemeral_disks`

Use this for a node-local tier that retains warmed contents and learned history
across storage pod restarts. The supplied LVM DaemonSet places raw data LVs and
a metadata filesystem on the **same Local SSDs**. This makes process persistence
useful without treating ephemeral SSDs as durable storage: replacement or loss of
those SSDs still requires a cold store.

Use the two files together:

- [partition-ephemeral-disks-daemonset.yaml](../custom-values/partition-ephemeral-disks-daemonset.yaml) prepares and verifies the node storage before labelling it `hermetiq/ephemeral-lvm=ready`.
- [buildbarn-values-local-ssd-block.yaml](../custom-values/buildbarn-values-local-ssd-block.yaml) selects persistent indexes for all five stores and points metadata hostPaths at the verified SSD mount.

The DaemonSet is not part of the Helm release. On a new pool, apply it by hand
first, wait until every storage node carries `hermetiq/ephemeral-lvm=ready`,
then install with the overlay layered after your base values:

```bash
kubectl apply -f custom-values/partition-ephemeral-disks-daemonset.yaml
kubectl get nodes -l node-type=ssd-block -L hermetiq/ephemeral-lvm
```

On a pool that already runs the 0.9.9 layout, do not apply it while storage is
serving: follow the [cut-over procedure](#cut-over-procedure-for-an-existing-local-ssd-pool).
Both the provisioner and hostPath storage containers require a namespace that
permits privileged pods. Run the [GKE validation](buildbarn-gke-storage-validation.md)
on a disposable pool when changing the node image, provisioning script, or disk
layout.

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

CAS takes every remaining extent (`lvcreate --extents 100%FREE`), so the volume
group is full as soon as the layout exists. On two 375 GiB SSDs the group has
749.992 GiB; the four fixed LVs take 32 GiB and CAS the remaining 717.992 GiB.
That has three consequences:

- The metadata LV cannot be extended later. There is no free extent to extend
  it with, and the provisioner never resizes an LV. A larger metadata LV means
  a new layout: a [reset](#resetting-a-local-ssd-node) of every node and a cold
  cache.
- The 16 GiB is fixed whatever the number of SSDs. A node with more SSDs gets a
  larger CAS LV and the same metadata LV.
- To keep slack, edit the script before the first provisioning; the layout is
  only ever created on an empty volume group. The first deployment of this
  layout replaced the `cas` line with a fixed `--size 700G`, which leaves about
  18 GiB of the group unallocated on two SSDs, and set
  `cas.blockDevice.size: 700Gi` to match. Using that slack later is a manual
  `lvextend` and `resize2fs` of `meta` with storage stopped, which this
  repository has not validated. An edited script is also no longer the script
  whose hashes are in the [validation record](buildbarn-gke-storage-validation.md#validation-record).

Every file-backed index, the shared CMS blocks file and each store's checkpoint
state live on the metadata LV. The index files plus the CMS blocks file must
fit it, with room left for ext4 overhead and checkpoint state:

| CAS LV | CAS index | All five index files | Plus 1024 MiB CMS blocks | In the 16 GiB LV (16384 MiB) |
|---|---|---|---|---|
| 718 GiB (two SSDs, overlay as shipped) | 7360 MiB | 11008 MiB | 12032 MiB | fits, 4352 MiB left |
| 1 TiB | 7680 MiB | 11328 MiB | 12352 MiB | fits, 4032 MiB left |
| 2 TiB | 15360 MiB | 19008 MiB | 20032 MiB | does not fit |

The CAS index is `cas.blockDevice.metadata.keyLocationMapSizeMi`; the 1 TiB and
2 TiB values are the ones the chart README uses for its
[large-scale profiles](../charts/buildbarn/README.md#large-scale-deployments-10-tib-cache--510-shards).
Every row keeps the overlay's other indexes: CMS 1280, AC 1344, ISCC 512 and
FSAC 512 MiB. Larger AC, ISCC or FSAC indexes add to the total. A node with six
375 GiB SSDs has a CAS LV of about 2218 GiB, past the last row: raise the
`meta` size in the script before provisioning such nodes.

Nothing checks that sum. The per-store `blockDevice.metadata.size` values are
documentary in hostPath mode. The chart compares each one with that store's own
index (and, for CAS, the shared CMS files) and fails the render when it is too
small, but the values reserve nothing on the node, and raising one makes the
render pass without making the LV any larger. bb-storage creates each index
file at full size but sparse, so a set of files larger than the LV starts
normally and runs out of space only as the indexes fill.

On startup the provisioner first installs its tools with `apk add`, and only
then sets its exit trap and clears `hermetiq/ephemeral-lvm`. The label is not
cleared when that install fails: without egress to the Alpine package mirror
the container exits before it touches the label. A label left at `ready` by an
ungraceful stop then stays `ready` with nothing verifying it, and a cleared
label stays cleared until egress returns. The init container installs
`util-linux` the same way. Every container restart and every node reboot
therefore depends on the package mirror unless the tools are baked into the
image.

With its tools installed, the provisioner verifies the layout
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
metadata hostPaths. That is the chart default since 0.10.0; the overlay sets it
explicitly, and values files of your own must not override it. A missing
per-store directory therefore fails mounting
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
layout, missing marker, or old full VG without `meta` fails closed. The
provisioner does not complete or repair such a layout; the way out is
[Resetting a Local SSD node](#resetting-a-local-ssd-node). Changing size values
does not resize existing LVs.

Implementation details:

- The manifest uses `alpine:3.20` and installs `lvm2`, `curl`, `e2fsprogs`, and `util-linux` at every container start (`util-linux` in the init container). For restricted-egress clusters, bake those packages into an image, set both `image:` fields, and remove the two `apk add` lines, which the script otherwise still runs.
- It uses classic LVM striping through `dm-mod`. LVM `--type raid0` requires `dm-raid`, which the target GKE COS image cannot load.
- Its `terminationMessagePath` is outside `/dev` because it bind-mounts the host's `/dev`.
- Its ServiceAccount can `get` and `patch` Nodes to manage the scheduling label.

### Cold cut-over and failure recovery

Existing layouts that allocated the entire VG to four data LVs cannot gain the
16 GiB metadata LV in place: the group has no free extent, and the provisioner
refuses to shrink a data LV. Every node needs a new layout, on replacement VMs
or by resetting the **whole** VG in place. Do not shrink CAS or recreate one
data LV while retaining its old metadata. The CDC upgrade already requires a
cold format cut-over; do both in one outage with the
[cut-over procedure](#cut-over-procedure-for-an-existing-local-ssd-pool) below.

Whenever devices are replaced or a VG is reset, drain builds and stop the
affected storage processes first. Recreate blocks and metadata together, wait
for the verified ready label, and start storage with the persistent overlay.
Check that old keys are missing and clean uploads/readback succeed. Restart
frontends before resuming clients so positive existence-cache entries do not
refer to the discarded data. There is no rollback copy on this path: Local SSD
contents survive neither VM replacement nor a reset, and metadata kept without
its blocks is never one.

**Never put persistent metadata on the boot disk or a network PVC while blocks
live on Local SSD.** A normal guest-OS reboot preserves Local SSD contents, but a
host-recovery failure can return the same VM with blank SSDs and an intact boot
disk. Surviving metadata can then advertise nonexistent blobs as present. See
Google's [Local SSD persistence and recovery behavior](https://cloud.google.com/compute/docs/disks/local-ssd#data_persistence).

If a storage pod stays Pending, inspect the provisioner on its intended node.
`kubectl logs ds/partition-ephemeral-disks` reads one arbitrary pod of the
DaemonSet, so select the pod by node:

```bash
kubectl get nodes -l node-type=ssd-block -L hermetiq/ephemeral-lvm
NODE=NODE_NAME   # a node without the ready label
POD=$(kubectl -n hermetiq get pods -l app=partition-ephemeral-disks \
  --field-selector spec.nodeName="$NODE" -o name)
kubectl -n hermetiq logs "$POD" -c partition
kubectl -n hermetiq logs "$POD" -c partition --previous
```

`--previous` prints the last failed start of a container that is restarting in
a loop; the reason is its `ERROR:` line. No raw SSDs usually means the node pool
was created without `--local-nvme-ssd-block`, or used
`--ephemeral-storage-local-ssd` instead. A legacy VG, missing metadata mount,
wrong filesystem, or generation mismatch is an intentional refusal to serve.
Never add the ready label by hand. [Resetting a Local SSD node](#resetting-a-local-ssd-node)
lists each message, what it means, and the way out.

For intentionally volatile indexes, apply
[buildbarn-values-ephemeral.yaml](../custom-values/buildbarn-values-ephemeral.yaml)
**after** this overlay. The overlay carries the RAM entry count that stack needs
for CAS (`keyLocationMapInMemoryEntries: 83000000`, unused while the index is
file-backed); recompute it when the CAS LV is not 718 GiB. That discards
cache/training state on each storage-process
restart and does not remove the need to handle frontend existence-cache entries
after a cold reset. Keep every enabled store on its intended Local SSD layout;
a filesystem hostPath outside the metadata mount can otherwise use the boot disk.
The chart fails the render when an enabled filesystem ISCC or FSAC store is
left on the chart default `hostPath.path` while CAS is a raw device.

### Cut-over procedure for an existing Local SSD pool

This is the cut-over for a pool that the 0.9.9 DaemonSet provisioned (four data
LVs filling the volume group, no `meta`) and that moves to chart 0.10.0 with
the Local SSD overlay. It discards the cache. Every shard starts empty, and
nothing of the pre-CDC stores is kept.

It runs inside the
[storage-format cutover runbook](buildbarn-storage-model.md#storage-format-cutover-and-rollback).
That runbook's step 1 (prerequisites), steps 2 and 3 (stop clients, then
storage), step 5 (upgrade, storage first) and step 6 (verify) apply as written.
Steps 4 to 6 below take the place of its step 4: there are no legacy files to
retire, because every node gets a new volume group and a new metadata
filesystem.

1. **Before the window: fix the size of the pool.** Keep the storage pool at a
   fixed node count with autoscaling off, during the cut-over and afterwards.
   While storage is stopped its nodes run only DaemonSet pods, which the
   cluster autoscaler is free to remove. Scaling a node away deletes its VM and
   its SSD contents; scaling up adds nodes, not shards.

   ```bash
   gcloud container node-pools describe POOL --cluster CLUSTER --location LOCATION \
     --format='value(autoscaling.enabled)'
   gcloud container clusters update CLUSTER --location LOCATION \
     --node-pool POOL --no-enable-autoscaling
   ```

   The first command prints `True` while autoscaling is on. If infrastructure
   code manages the pool, make the change there, or its next run turns
   autoscaling back on.

2. **Before the window: confirm the old layout and choose how to replace it.**
   The 0.9.9 provisioner pods have the LVM tools:

   ```bash
   POD=$(kubectl -n hermetiq get pods -l app=partition-ephemeral-disks -o name | head -n 1)
   kubectl -n hermetiq exec "$POD" -c partition -- vgs -o vg_name,vg_size,vg_free ephemeral
   kubectl -n hermetiq exec "$POD" -c partition -- lvs -o lv_name,lv_size ephemeral
   ```

   A `VFree` of `0` and no `meta` LV is the old layout. It cannot be converted
   in place, so each node needs one of:

   - **Replacement VMs** (step 5a). This needs Local SSD capacity for a second
     set of nodes while both pools exist.
   - **A reset of its SSDs in place** (step 5b). This needs no new capacity,
     and a privileged pod on each node.

   `kubectl delete node` does neither. It removes the Node object only: the VM
   keeps running with its disks untouched, the kubelet registers the node
   again, and the provisioner finds the same legacy volume group.

   In the target values, set `cas.blockDevice.size` to the CAS LV the new
   layout produces (`718Gi` on two 375 GiB SSDs with the script as shipped)
   and `storage.replicas` to the number of storage nodes.

3. **Stop clients, then storage.** Follow steps 2 and 3 of the runbook. There
   is nothing to snapshot on this path. Do not continue while a storage pod
   exists:

   ```bash
   kubectl -n hermetiq get pods -l app=storage -o wide
   ```

4. **Apply the new provisioner by hand.** `helm upgrade` does not apply it.

   ```bash
   kubectl apply -f custom-values/partition-ephemeral-disks-daemonset.yaml
   ```

   On a node that still has the old layout, the new pod clears the ready label
   and fails with `ERROR: legacy VG has no metadata LV; cold cut-over on fresh
   SSDs is required (no data was resized or erased)`, then restarts in a loop.
   That is expected until the node is replaced or reset. The DaemonSet's
   rolling update (`maxUnavailable: 1` by default) stops at the first node
   that fails this way, so the other old nodes keep their 0.9.9 pod and its
   `ready` label. Do not wait for `kubectl rollout status`.

5. **Give every storage node the new layout.** Never carry an old index or
   checkpoint directory over to the new metadata filesystem.

   - **5a. Replace the VMs.** Create the replacement pool before deleting
     anything. Local SSD capacity can be out of stock in a zone, and a VM
     deleted first may not come back. Use the old pool's machine type, Local
     SSD count, zones, image type and service account, the same label and
     taint, and neither autoscaling nor Spot:

     ```bash
     gcloud container node-pools create NEW_POOL --cluster CLUSTER --location LOCATION \
       --machine-type MACHINE_TYPE --local-nvme-ssd-block count=SSD_COUNT \
       --image-type IMAGE_TYPE --service-account SERVICE_ACCOUNT \
       --num-nodes NODES_PER_ZONE --node-locations ZONES \
       --node-labels node-type=ssd-block \
       --node-taints hermetiq/ssd-block=true:NoSchedule
     ```

     If the pool cannot be created or comes up short, the old pool is still
     there: retry, or reset in place instead. Once step 6 passes on every new
     node, delete the old pool, and do it before storage starts. An old node
     can still carry `hermetiq/ephemeral-lvm=ready` from the 0.9.9
     provisioner, which never revoked it, and a storage pod scheduled there
     cannot mount its metadata directories.

     ```bash
     gcloud container node-pools delete OLD_POOL --cluster CLUSTER --location LOCATION
     ```

   - **5b. Reset in place.** Follow
     [Resetting a Local SSD node](#resetting-a-local-ssd-node) for each node.
     Reset one node, pass step 6 on it, then do the others.

6. **Verify every node before starting storage.** A ready label or a
   successful provisioning log line is not enough.

   ```bash
   kubectl get nodes -l node-type=ssd-block -L hermetiq/ephemeral-lvm
   kubectl -n hermetiq get pods -l app=partition-ephemeral-disks -o wide
   ```

   Every storage node must show `ready` and a provisioner pod in state
   `Running` with `1/1` containers ready, and there must be at least
   `storage.replicas` such nodes: the overlay's anti-affinity puts one shard
   on each. Then check each node from its provisioner pod:

   ```bash
   META=/mnt/stateful_partition/buildbarn-local-ssd/metadata
   for POD in $(kubectl -n hermetiq get pods -l app=partition-ephemeral-disks -o name); do
     echo "== $POD"
     kubectl -n hermetiq exec "$POD" -c partition -- /tmp/check-metadata-ready
     kubectl -n hermetiq exec "$POD" -c partition -- \
       awk -v m="$META" '$5 == m' /proc/1/mountinfo
     kubectl -n hermetiq exec "$POD" -c partition -- \
       lvs --units g -o lv_name,lv_size ephemeral
     kubectl -n hermetiq exec "$POD" -c partition -- \
       stat -c '%n %u:%g:%a' "$META/cas" "$META/ac" "$META/iscc" "$META/fsac"
   done
   ```

   | Check | Required result |
   |---|---|
   | `/tmp/check-metadata-ready` | Prints nothing and exits 0. This is the provisioner's own check of the filesystem type, mount, generation marker and directory ownership. |
   | `awk` on `/proc/1/mountinfo` | A line naming `ext4` and `/dev/mapper/ephemeral-meta`. This is the mount as the host sees it, not only the provisioner container. No output means the host does not have it. |
   | `lvs` | `meta` 16.00g, `ac` 8.00g, `iscc` 2.00g, `fsac` 6.00g, and `cas` with the rest: 717.99g on two 375 GiB SSDs. `cas.blockDevice.size` in the values must be this size rounded up to a whole GiB. |
   | `stat` | `65534:65534:770` for each of the four directories. |

   While the old pool of step 5a still exists, its pods are in that loop too
   and fail these checks. Judge the new nodes, then delete the old pool.

7. **Upgrade.** Continue with step 5 of the runbook, with the Local SSD
   overlay after your base values, then step 6. On this path:

   - The storage StatefulSet has no volume claim templates in hostPath mode,
     before or after, so that step's StatefulSet deletion does not apply.
   - A storage pod stays Pending until a node carries
     `hermetiq/ephemeral-lvm=ready`, and it cannot start on a node whose
     metadata directories or LVs are absent.
   - The old devices and indexes are gone, so the first builds upload
     everything again.

**Rollback is another cold reset.** Local SSD contents cannot be kept across VM
replacement, and the in-place reset discards them, so no copy of the pre-CDC
stores exists to restore. To go back, stop clients and storage again, return
every node to the layout the old release expects (replace or reset the nodes
again and apply that release's DaemonSet), and deploy the old chart and values
as the runbook's rollback paragraph describes. Both directions start with an
empty cache.

### Resetting a Local SSD node

The provisioner fails closed and repairs nothing. In each of these states it
exits, leaves the node without the ready label, and fails the same way on every
restart:

| `ERROR:` line in the provisioner log | State |
|---|---|
| `legacy VG has no metadata LV; cold cut-over on fresh SSDs is required (no data was resized or erased)` | A 0.9.9 layout, or a first provisioning that stopped before `meta` was created. |
| `existing VG is missing <lv>; reset blocks and metadata together` | A partial layout: a first provisioning that stopped while the LVs were being created, or an LV that was removed. |
| `metadata generation marker missing; cold cut-over is required` | A first provisioning that stopped after `meta` was formatted and before the marker was written, or a deleted marker. |
| `data/metadata generation mismatch; stop storage and reset blocks and metadata together` | An LV or the metadata filesystem was recreated after the marker was written. |
| `VG missing while metadata remains published; stop consumers and inspect the old mount before any reset` | The SSDs were discarded or replaced underneath a metadata filesystem that is still mounted. |
| `unmounted metadata publication directory is not empty; inspect boot-disk leftovers before retrying` | Directories exist on the boot disk at the metadata mountpoint, created for a pod whose metadata hostPath type was `DirectoryOrCreate`. A storage pod that ran on them wrote to the data LVs with its indexes on the boot disk, so the indexes on `meta` no longer describe the blocks. |

The first three include a node that never held data. A first provisioning that
is interrupted between creating the LVs and writing the marker (a DaemonSet
re-apply or rollout restart, a killed container) cannot be finished by a
restart: the script creates LVs, formats `meta` and writes the marker only
when it finds no volume group at all. A node that stopped between the last
`lvcreate` and `mkfs.ext4` shows a failed `mount` of `/dev/ephemeral/meta`
instead of an `ERROR:` line. The way out of every one of these states is the
reset below, or replacing the VM. The reset destroys everything on the node's
SSDs, so that shard starts empty.

Do not improvise a shorter reset. The script defeats the obvious ones:

- **Unmounting the metadata alone does nothing.** The provisioner's monitor
  runs the check every five seconds and exits when the mount is gone. The
  restarted container then mounts the same filesystem, verifies the same
  marker and labels the node ready again. A shell opened with `kubectl exec`
  in that container ends with it.
- **Losing the volume group while the metadata is still published wedges the
  node.** If the SSDs are discarded first, the volume group is gone but the
  mount is not, and the provisioner refuses on every start with the `VG
  missing while metadata remains published` error. Unmount first.
- **A provisioner that is restarting in a loop cannot be used for the
  repair.** `kubectl exec` has no running container to enter. The commands
  below run from a separate privileged pod.
- **The ready label does not stop a running storage pod**, and that pod holds
  the metadata filesystem and the data LVs open. Storage must be gone from the
  node before anything is unmounted or removed.

This is the reset the [validation run](buildbarn-gke-storage-validation.md#validation-record)
performed for its whole-layout rows: consumers stopped, the volume group
removed, every SSD discarded with `blkdiscard`, and the layout recreated with
new identities. The record does not list its commands. The ones below are
derived from the provisioner script, so run them on one node and check each
result before repeating them on the others.

1. **Stop storage and the provisioner on the node, and keep them off.** Drain
   builds first unless clients are already stopped: with a shard missing,
   cache requests fail cluster-wide. A `NoExecute` taint that neither pod
   tolerates removes both, and any other pod on the node without a matching
   toleration, and stops the DaemonSet from recreating its pod:

   ```bash
   NODE=NODE_NAME   # the node to reset
   kubectl taint nodes "$NODE" hermetiq/local-ssd-reset=true:NoExecute
   kubectl -n hermetiq get pods -o wide --field-selector spec.nodeName="$NODE"
   ```

   Wait until that list shows no `storage-*` and no
   `partition-ephemeral-disks-*` pod. The storage pod is deleted with its
   normal termination grace period (120 s by default), and its replacement
   stays Pending. If your values give storage a toleration that matches every
   taint, the pod is not removed: scale `statefulset/storage` to `0` instead.

2. **Start a privileged pod on the node.** It mirrors the provisioner's
   container: the same image, the host's `/dev`, host PID, and the
   `DM_DISABLE_UDEV=y` setting the script exports before it calls LVM. It mounts
   nothing else from the host, so it cannot hold the metadata filesystem open.
   Do not use `kubectl debug node/` here: it mounts the host's root filesystem
   into the debug container, and that copy of the metadata mount can keep the
   LV busy after the host has unmounted it.

   ```bash
   kubectl apply -f - <<EOF
   apiVersion: v1
   kind: Pod
   metadata:
     name: local-ssd-reset
     namespace: hermetiq
   spec:
     nodeName: $NODE
     hostPID: true
     restartPolicy: Never
     tolerations:
       - operator: Exists
     containers:
       - name: reset
         image: alpine:3.20
         command: ["sleep", "3600"]
         terminationMessagePath: /tmp/termination-log
         securityContext:
           privileged: true
         env:
           - name: DM_DISABLE_UDEV
             value: "y"
         volumeMounts:
           - name: dev
             mountPath: /dev
     volumes:
       - name: dev
         hostPath:
           path: /dev
           type: Directory
   EOF
   kubectl -n hermetiq wait --for=condition=Ready pod/local-ssd-reset --timeout=120s
   kubectl -n hermetiq exec -it local-ssd-reset -- sh
   ```

   The remaining commands of steps 3 to 5 run in that shell. Install the
   tools first (this needs the same package-mirror egress as the provisioner):

   ```sh
   apk add --no-cache lvm2 device-mapper util-linux
   ```

3. **Unmount the published metadata path on the host.** The mount lives in the
   host's mount namespace, which is where the init container of the DaemonSet
   also works:

   ```sh
   META=/mnt/stateful_partition/buildbarn-local-ssd/metadata
   nsenter --target 1 --mount --root --wd -- umount "$META"
   grep "$META" /proc/1/mountinfo
   grep -l ephemeral-meta /proc/[0-9]*/mountinfo
   nsenter --target 1 --mount --root --wd -- ls -A "$META"
   ```

   `umount` or `ls` reporting that the path is not mounted or does not exist
   is fine: a legacy or partial layout never published it. Otherwise the three
   checks must print nothing.
   A line from the first `grep` means the path is still mounted on the host.
   A file name from the second is a process that still has the filesystem
   mounted, usually a storage container: stop it before going on. Output from
   `ls` is directories on the boot disk at the mountpoint: inspect them, set
   the metadata hostPath type back to `Directory` in the values that created
   them, and remove them, or the provisioner refuses to publish. Remove them
   from the same shell, and only after the first `grep` printed nothing:
   `nsenter --target 1 --mount --root --wd -- rm -rf "$META/cas" "$META/ac" "$META/iscc" "$META/fsac"`.

4. **Deactivate and remove the volume group.**

   ```sh
   vgchange --activate n ephemeral
   vgremove --force ephemeral
   ```

   If `vgchange` reports an LV in use, something still has it open: go back to
   step 3. If both commands report that the volume group is not found while
   `ls /dev/mapper/ephemeral-*` still lists devices, the SSDs were discarded
   underneath an active volume group. Remove the leftover mappings instead:

   ```sh
   for lv in meta cas ac iscc fsac; do dmsetup remove "ephemeral-$lv"; done
   ```

5. **Discard every Local SSD.** The device list is the one the provisioner
   uses. The devices still carry LVM labels, which `blkdiscard` refuses to
   discard when its input is a terminal, so give it `/dev/null` as input. Do
   not use `--force`: it also drops the exclusive open that makes `blkdiscard`
   fail on a device a volume group still holds. A `Device or resource busy`
   error means step 4 is not finished.

   ```sh
   for link in /dev/disk/by-id/google-local-nvme-ssd-*; do
     blkdiscard "$(readlink -f "$link")" </dev/null
   done
   exit
   ```

6. **Start the provisioner again and verify.** Remove the pod, then the taint:

   ```bash
   kubectl -n hermetiq delete pod local-ssd-reset
   kubectl taint nodes "$NODE" hermetiq/local-ssd-reset-
   ```

   The DaemonSet starts a provisioner on the node. It finds no volume group
   and no published mount, creates the layout from scratch, and labels the
   node ready. Run the checks of
   [cut-over step 6](#cut-over-procedure-for-an-existing-local-ssd-pool) on
   the node. Storage then schedules there and starts empty (scale
   `statefulset/storage` back up if you scaled it down). Outside a cut-over,
   restart the frontends before resuming clients so their positive
   existence-cache entries for the discarded shard are dropped.

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

Set `blockDevice.metadata.storageClassName: topolvm-ssd` for every store, as
shown above, so each companion metadata PVC uses the same local device class as
its blocks. The class is not inherited from the blocks: the chart default for
every metadata claim is `premium-rwo`, and values that omit the line put the
index on a network disk under local blocks.

That pairing breaks without anyone touching it. When a Node object is deleted
(node upgrade, repair or scale-down), TopoLVM's controller by default deletes
the PVCs of its own StorageClasses on that node and leaves every other claim
alone. The StatefulSet controller then creates new, blank `<store>-blocks`
volumes and attaches the surviving `<store>-meta` claims again by name, and
the surviving index reports blobs that no longer exist. With metadata on
`topolvm-ssd`, blocks and metadata are deleted together and the shard starts
cold. On install or upgrade the Helm notes print
`WARNING: STORAGE CLASS MISMATCH` for each store whose two classes differ; the
render does not fail.

A 0.9.9 install of this example ran in-memory indexes: four `<store>-blocks`
claim templates and no metadata claims. Upgraded with its values unchanged,
AC, ISCC and FSAC gain `<store>-meta` claims on `premium-rwo`, and CAS does too
once its explicit `keyLocationMap: inMemory` is removed. Choose one of:

- **Keep the indexes volatile.** Apply the
  [ephemeral profile](buildbarn-storage-operations.md#explicit-ephemeral-opt-out)
  last. The StatefulSet then renders the same four claim templates as on
  0.9.9, so nothing is recreated.
- **Adopt persistent indexes.** Set `blockDevice.metadata.storageClassName`
  for all four stores (and for a dedicated raw CMS), then follow
  [Recreate the Storage StatefulSet](buildbarn-storage-operations.md#recreate-the-storage-statefulset).

Either way an existing release keeps the device sizes it was created with, and
its index sizes must follow them. The 0.9.9 example used `8Gi` for ISCC and
FSAC. With `storage.keyLocationMapSizing.validate: true`, an `8Gi` ISCC device
needs `blockDevice.keyLocationMapInMemoryEntries: 30758230` or more in memory,
or a `1936` MiB file index with `blockDevice.metadata.size: 3Gi`, and a
volatile `700Gi` CAS needs at least `80465592` in-memory entries.

Unlike hostPath mode, `blockDevice.size` matters here because it is the PVC request and therefore the logical volume size TopoLVM carves for each replica.

Device ownership uses the same `deviceAccess` choices as the Persistent Disk example: try `group` only if your CSI driver presents group-accessible devices, otherwise use `chownInit`. The long-lived storage container remains non-privileged, which is the main operational advantage over the hostPath local SSD path.

Keep each blocks PVC and metadata PVC on the same local StorageClass/device
class. Never pair these local blocks with the default network `premium-rwo`
metadata claim. A claim keeps the class it was created with, so correcting the
value later does not move an existing `<store>-meta-storage-<i>` claim: delete
it, with its blocks claim, while the shard is stopped. Co-location does not
make an independent PVC reset safe: after
loss/recreation of either member, stop the shard and reset/delete the matching
`<store>-blocks` and `<store>-meta` claims together. Restore rollback snapshots
only as a consistent pair. Shared CMS is part of the CAS metadata claim.
