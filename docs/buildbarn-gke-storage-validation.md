# Validate Buildbarn's same-SSD metadata layout on GKE

This procedure verifies the [Local SSD example](buildbarn-block-storage.md#gke-example-b-local-nvme-ssd-with-partition_ephemeral_disks)
on real GKE nodes. Helm rendering and stubbed LVM tests cannot prove mount
propagation, COS device access, or reboot recovery. Use a disposable node pool
and a separate namespace in the target cluster; never run loss/reset tests on
an occupied storage node.

It validates a node image, provisioning script or disk layout. It does not
migrate anything. To move an existing storage pool to this layout, follow the
[cut-over procedure for an existing Local SSD pool](buildbarn-block-storage.md#cut-over-procedure-for-an-existing-local-ssd-pool).
To get a node out of a state the provisioner refuses, follow
[Resetting a Local SSD node](buildbarn-block-storage.md#resetting-a-local-ssd-node).

The required outcome is that blocks, indexes, and checkpoints survive ordinary
restarts together, or become a clean empty store together after SSD loss. A
surviving index must never tell clients that missing bytes are still available.

## Isolate the validation shard

Match the target storage pool's machine type, COS image, GKE version, service
account, raw Local SSD count, and zone. Give the validation pool its own node
label and `NoSchedule` taint. Neither the existing partitioning DaemonSet nor
application storage/workers should match those nodes. Specify one node in one
zone explicitly when creating a regional-cluster pool.

Deploy the repository's partitioning manifest with only its namespace, resource
names, node selector, and toleration adjusted for isolation. Keep the script,
mounts, security context, readiness probe, and RBAC rules identical to the source.
Deploy a one-replica storage shard rendered from the chart and Local SSD overlay,
with ISCC and FSAC enabled and shared CMS. Isolate its service names/configuration
so it never joins the application shard set or receives real build traffic.

Before starting, record:

- Chart commit, rendered values/manifests, storage image digest, and provisioner script checksum.
- Cluster/context, namespace, node pool, node name, zone, GKE version, and COS image.
- LV sizes/UUIDs, filesystem UUID, metadata marker, and per-store ownership.
- The exact resources created so cleanup removes only validation resources.

Use an explicit context for every command. For example:

```bash
CTX=gke_hermetiq-cloud_us-south1_test-uss1
NS=pr79-storage-validation
kubectl --context "$CTX" -n "$NS" get pods -o wide
kubectl --context "$CTX" get nodes -L cloud.google.com/gke-nodepool,hermetiq/ephemeral-lvm
```

## Verify physical placement before RPC tests

Set `PROVISIONER_POD` and `STORAGE_POD` to the isolated pods. Check the provisioner
mount and identity using its actual verifier, rather than the existence of a
directory alone:

```bash
kubectl --context "$CTX" -n "$NS" exec "$PROVISIONER_POD" -- /tmp/check-metadata-ready
kubectl --context "$CTX" -n "$NS" exec "$PROVISIONER_POD" -- \
  findmnt --mountpoint /mnt/stateful_partition/buildbarn-local-ssd/metadata \
  -o TARGET,SOURCE,FSTYPE,UUID,OPTIONS
kubectl --context "$CTX" -n "$NS" exec "$PROVISIONER_POD" -- \
  lvs --units b -o vg_name,lv_name,lv_size,lv_uuid,devices ephemeral
kubectl --context "$CTX" -n "$NS" exec "$PROVISIONER_POD" -- \
  cat /mnt/stateful_partition/buildbarn-local-ssd/metadata/.buildbarn-layout-v1
```

Confirm `meta` and all four data LVs use the same raw NVMe PVs. The metadata LV
must be 16 GiB, ext4, and writable; its UUID must match both the mounted filesystem
and marker. Store directories must be `65534:65534` with mode `0770`. Record the
actual CAS size and keep the overlay's documentary `blockDevice.size` consistent
with it, because index sizing validation uses that value.

Also verify the mount **in the host mount namespace**, not just inside the
provisioner container. The DaemonSet uses `hostPID: true`, so host PID 1's mount
table is available from its container:

```bash
kubectl --context "$CTX" -n "$NS" exec "$PROVISIONER_POD" -c partition -- \
  awk '$5 == "/mnt/stateful_partition/buildbarn-local-ssd/metadata" {print; found=1}
       END {exit !found}' /proc/1/mountinfo
```

The matching host mount must show the metadata LV's device identity and ext4.
Check the storage container's mount table through the host-PID provisioner or a
debug container targeting storage. Its four metadata mounts must resolve to that
filesystem, and the generated configuration must place all indexes/checkpoints
there. Verify storage runs as UID 65534 and the chart's init path grants access to
the raw devices. A ready label or successful provisioning log alone is insufficient.

## Seed and verify all five stores

Forward the isolated storage pod's RPC port:

```bash
kubectl --context "$CTX" -n "$NS" port-forward "pod/$STORAGE_POD" 18981:8981
```

In another terminal, retain the probe manifests outside the cluster:

```bash
PROBE=charts/buildbarn/tests/storage_gke_probe.py
EVIDENCE_DIR=/tmp/buildbarn-gke-validation
mkdir -p "$EVIDENCE_DIR"
uv run --no-project --with protobuf --with grpcio python3 "$PROBE" \
  --endpoint 127.0.0.1:18981 --manifest "$EVIDENCE_DIR/checkpoint.json" \
  --seed checkpoint seed
```

The probe writes deterministic 11 KiB, 512 KiB, and 3 MiB blobs, an AC entry
referencing their digests, ISCC scheduling history, and an FSAC bloom filter.
For the 3 MiB object, the probe calls `SplitBlob`, requires more than one
RepMaxCDC chunk, and verifies each returned chunk digest against the original
bytes. This explicitly verifies CMS coverage. Every successful check compares
full contents, including AC metadata and both learning records. Capture stdout
and storage logs for each stage.

Run this matrix, restarting port-forward whenever the storage pod changes:

| Test | Action | Required result |
|---|---|---|
| Fresh provisioning | Start on blank validation SSDs | `meta` is formatted and mounted before the ready label appears; all store mounts and permissions are correct |
| Graceful pod replacement | Delete the isolated storage pod with its normal grace period | `check` passes; stored contents and learned history survive |
| Provisioner replacement | Delete the isolated provisioner pod, then replace storage | No `mkfs` or LV recreation; UUIDs/marker unchanged; `check` passes |
| Guest-OS reboot | Reboot only the validation node, then wait for verified mount and storage readiness | Same UUIDs and host mount return; `check` passes |
| Abrupt storage death | After a checkpoint, seed a second manifest and send actual SIGKILL to the isolated storage process | Checkpoint `check` passes; `present-readable` passes for both fixture generations |
| Independent data-LV recreation | Stop isolated storage; recreate one data LV while preserving metadata | Provisioner refuses readiness with a generation mismatch; storage is kept stopped |
| Whole-layout loss/reset | Stop isolated storage and replace/reset the complete validation VG, including `meta` | New UUIDs/marker; `empty` passes for every old manifest; reseeding and `check` succeed |

A normal reboot is not a disk-loss test. Google documents that [guest-OS reboot
preserves Local SSD data, while some host-recovery failures lose it](https://cloud.google.com/compute/docs/disks/local-ssd#data_persistence).
Exercise a deliberate whole-layout reset separately on the disposable node,
using the sequence in [Resetting a Local SSD node](buildbarn-block-storage.md#resetting-a-local-ssd-node)
with the validation namespace and resource names.
Do not use a forced Kubernetes object deletion as evidence of SIGKILL: record
the actual process/container termination and subsequent recovery.

After a graceful checkpoint/restart, verify retained fixtures:

```bash
uv run --no-project --with protobuf --with grpcio python3 "$PROBE" \
  --manifest "$EVIDENCE_DIR/checkpoint.json" check
```

For crash recovery, seed `recent.json` with `--seed recent` after that checkpoint,
then kill storage immediately. Recent uncheckpointed writes may disappear; any
blob advertised as present must be readable:

```bash
uv run --no-project --with protobuf --with grpcio python3 "$PROBE" \
  --manifest "$EVIDENCE_DIR/recent.json" --seed recent seed
```

After the actual SIGKILL and storage recovery:

```bash
uv run --no-project --with protobuf --with grpcio python3 "$PROBE" \
  --manifest "$EVIDENCE_DIR/checkpoint.json" check
uv run --no-project --with protobuf --with grpcio python3 "$PROBE" \
  --manifest "$EVIDENCE_DIR/checkpoint.json" present-readable
uv run --no-project --with protobuf --with grpcio python3 "$PROBE" \
  --manifest "$EVIDENCE_DIR/recent.json" present-readable
```

After complete SSD/VG loss, `empty` requires all CAS digests to be missing and
their reads to return `NOT_FOUND`; `SplitBlob` must report the composite mapping
missing, and AC, ISCC, and FSAC must also return `NOT_FOUND`. Then re-upload the
same fixtures:

```bash
uv run --no-project --with protobuf --with grpcio python3 "$PROBE" \
  --manifest "$EVIDENCE_DIR/checkpoint.json" empty
uv run --no-project --with protobuf --with grpcio python3 "$PROBE" \
  --manifest "$EVIDENCE_DIR/recent.json" empty
uv run --no-project --with protobuf --with grpcio python3 "$PROBE" \
  --manifest "$EVIDENCE_DIR/checkpoint.json" seed
uv run --no-project --with protobuf --with grpcio python3 "$PROBE" \
  --manifest "$EVIDENCE_DIR/checkpoint.json" check
```

Collect logs **before** removing each storage container/pod. Check every lifetime
for integrity, checksum, and decompression failures. This isolated RPC probe
bypasses the frontends and their existence caches; a deployed release's cold
cut-over has to deal with them, as its
[own procedure](buildbarn-block-storage.md#cut-over-procedure-for-an-existing-local-ssd-pool)
describes.

## Limits and cleanup

The scheduling label does not evict an existing storage pod. Keep storage stopped
during failure injection and lifecycle repair. UUID checks identify replacement
LVs; they do not detect arbitrary in-place corruption that preserves identities.
A deliberately erased single LV with retained metadata remains an unsupported
state and requires a paired reset.

Record outcomes and evidence for every matrix row before calling a node image or
layout validated. Preserve the chart commit, scripts, values, logs and probe
manifests with that result. Remove the validation namespace, its cluster-scoped
RBAC, and disposable node pool after collecting evidence; confirm the original
storage shards stayed healthy throughout.

## Validation record

Validated on **2026-11-20** using a disposable replica in the existing test-uss1
cluster. This exercised the raw Local SSD layout with shared CMS and all five
stores enabled. It did not change the existing `hermetiq` Helm release or its
three storage shards, and it does not establish TopoLVM or other CSI behavior.

| Field | Validation target |
|---|---|
| Cluster/context | `gke_hermetiq-cloud_us-south1_test-uss1` |
| Namespace and node pool | `pr79-storage-validation` |
| Zone | `us-south1-c` |
| Node | `gke-test-uss1-pr79-storage-validation-7ce8f90e-ggdb` |
| Machine and disks | `n2-standard-16`; two raw NVMe Local SSDs, each exposing `402653184000` bytes (375 GiB) |
| GKE | `1.35.8-gke.1796000` |
| Node OS/runtime | COS 125; kernel `6.12.105`; containerd `2.2.7` |

Fresh provisioning passed after adding the COS host-mount initialization step.
The dedicated parent is shared, and the host sees the ext4 filesystem from
`/dev/mapper/ephemeral-meta` at the intended metadata path. Its filesystem UUID
matches `blkid`, and store directories are `65534:65534:770`. The observed CAS
device is `770938241024` bytes (717.9921875 GiB); the overlay rounds its sizing
input up to `718Gi`.

The tested source was PR #79's working tree after `2f8eb44`, including the
provisioner and enabled-store changes in this commit. The deployed main and init
commands were compared byte-for-byte with the repository source. SHA-256 of each
command array joined with newlines:

- `partition`: `da4f9113f087735c89a59101ab5c2da40f5bfb3a795582ab065a9c901b8315ea`
- `prepare-metadata-parent`: `bf6e777c834e18eb51fa38a247774e12c2685a0e265949c5c6e0d7601870fb68`

Both hashes still describe
[the manifest in this repository](../custom-values/partition-ephemeral-disks-daemonset.yaml).
The comments in its YAML header have changed since the run; they are not part
of either command array. Any edit to the script text, including a comment
inside it, changes the hash and makes it a script this record does not cover.
To recompute (use `initContainers[0]` for `prepare-metadata-parent`):

```bash
yq -o=json 'select(.kind == "DaemonSet") | .spec.template.spec.containers[0].command' \
  custom-values/partition-ephemeral-disks-daemonset.yaml |
  python3 -c 'import hashlib, json, sys; print(hashlib.sha256("\n".join(json.load(sys.stdin)).encode()).hexdigest())'
```

Storage ran `ghcr.io/buildbarn/bb-storage:20261118T120531Z-06739f2`, resolved to
`sha256:53f9b3834b6bc565bb1160e28f82d7750e00278413f89e9ebcee8519657a03ee`.
The Local SSD overlay as it was at the time of the run rendered the same
storage ConfigMap, StatefulSet, and Service used in the test. Isolation
overrides changed the namespace, node selector and toleration, disabled
unrelated routing, and disabled AC expiry while testing exact metadata
equality.

Two sizes have changed since the run, neither in the provisioner nor in the
layout: the chart default for the shared CMS index rose from 256 MiB to
1280 MiB, and the overlay's storage memory request from `12Gi` to `16Gi`. The
tested render therefore put 9984 MiB of index files and 1024 MiB of CMS blocks
on the 16 GiB metadata LV; the current overlay puts 11008 MiB and 1024 MiB
there.

| Live test | Observed result |
|---|---|
| Fresh provisioning and access | PASS: metadata on both NVMe PVs; host and storage mounts resolve to the metadata LV; storage UID 65534; both chart init containers succeed |
| Graceful storage pod replacement | PASS: all three fixture blobs, AC entry, ISCC history, and FSAC profile retained |
| Provisioner replacement | PASS: existing LVs activated without formatting; stored contents remain readable |
| SIGKILL | PASS: checkpointed fixtures retained; three newer blobs and their cache records reported missing; every blob reported present was readable |
| Guest-OS reboot | PASS: boot ID changed, all seven VG/LV/filesystem identities remained unchanged, automatic activation/remount succeeded, and the retained composite blob reconstructed from ten verified chunks |
| One data LV recreated with old metadata | PASS: generation mismatch rejected, ready label absent, public metadata mount absent; a pod pinned directly to the node failed its `Directory` hostPath mount |
| Both SSDs discarded | PASS: after stopping consumers and removing the VG, `blkdiscard` completed on both NVMe devices; the recreated layout had new identities; all six prior blobs and their CMS/AC/ISCC/FSAC records were missing |
| Re-upload after reset | PASS: both fixture sets readable again; composite blobs reconstructed from ten and nine verified chunks |

Seven collected storage lifetime logs contained no integrity failures. The
existing three `hermetiq` storage shards remained Ready with zero restarts.
The SIGKILL result deliberately allows uncheckpointed writes to disappear;
persistent storage does not promise that every acknowledged write survives an
abrupt process death.

The evidence (`results.json`, rendered manifests, probe manifests,
mount/identity snapshots, failure-injection evidence and logs) was kept by the
engineer who ran the validation. It is not in this repository, and this record
is the only part of it published here. Cleanup is complete: the namespace,
cluster-scoped RBAC, both temporary node pools (including the alternate-zone
capacity retry), their nodes, and their VMs were removed. The existing deployment
and its three Ready storage shards were left unchanged; adopting this layout
there still requires the
[cut-over procedure for an existing Local SSD pool](buildbarn-block-storage.md#cut-over-procedure-for-an-existing-local-ssd-pool).
