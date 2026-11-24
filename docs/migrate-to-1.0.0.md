# Migrating to 1.0.0

This guide is for installations that run a release from before the `1.0.0`
chart bundle: Hermetiq `0.9.8` or earlier, Buildbarn `0.9.9` or earlier, or BB
Worker Operator `0.3.12` or earlier. A new installation needs none of it;
follow the [installation guide](../README.md#installation).

`1.0.0` is a cut-over, not a rolling upgrade:

- Buildbarn `1.0.0` stores data in the CDC (RepMaxCDC) format and renders CDC
  configuration. It cannot read the cache an earlier release wrote, so every
  store starts empty.
- Hermetiq `1.0.0` reads Buildbarn configuration in that schema only, and
  enforces project authorization for every caller.
- BB Worker Operator `1.0.0` generates the matching worker configuration and
  nothing else.

Upgrade the three charts in one maintenance window, and do not leave any of
them running with earlier versions of the others. The charts do not check
each other's versions.

| Chart | From | To | Guide |
|---|---|---|---|
| Hermetiq | `0.9.8` or earlier | `1.0.0` | [Migrating the Hermetiq chart](migrate-to-1.0.0-hermetiq.md) |
| BB Worker Operator | `0.3.12` or earlier | `1.0.0` | [Migrating the BB Worker Operator chart](migrate-to-1.0.0-bb-worker-operator.md) |
| Buildbarn | `0.9.9` or earlier | `1.0.0` | [Migrating the Buildbarn chart](migrate-to-1.0.0-buildbarn.md) |

## Before the window

1. Read the `Chart.yaml` release metadata and GitHub release notes of each
   chart.
2. Compare the new defaults with the version currently deployed, for example:

   ```bash
   helm show values oci://ghcr.io/hermetiq/hermetiq \
     --version 0.9.8 > /tmp/hermetiq-old-values.yaml
   helm show values oci://ghcr.io/hermetiq/hermetiq \
     --version 1.0.0 > /tmp/hermetiq-new-values.yaml
   diff -u /tmp/hermetiq-old-values.yaml /tmp/hermetiq-new-values.yaml
   ```

3. Back up PostgreSQL. Hermetiq schema migrations run through the chart's
   bootstrap job before the workloads roll.
4. Prepare Hermetiq access grants and admission settings. An existing Hermetiq
   `0.9.8` install needs them in place before the upgrade, or builds stop
   publishing; see
   [Prepare access and images](migrate-to-1.0.0-hermetiq.md#prepare-access-and-images).
5. Prepare the Buildbarn release: migrate custom Jsonnet and worker
   ConfigMaps, remove old image pins, check capacity for the new defaults, and
   decide whether you need a rollback snapshot. See
   [Upgrading configurations to CDC](migrate-to-1.0.0-buildbarn.md#upgrading-configurations-to-cdc)
   and
   [Migrate to persistent indexes](migrate-to-1.0.0-buildbarn.md#migrate-to-persistent-indexes).
6. Check the operator's `specPolicy` against your `RbeWorker` objects when
   coming from operator chart `0.3.10` or earlier; see
   [Upgrading to 0.3.11](migrate-to-1.0.0-bb-worker-operator.md#upgrading-to-0311).
7. Keep complete values files for every release. Do not use `--reuse-values`
   to change chart version: Helm then drops the new chart's defaults, and
   Buildbarn `1.0.0` does not render that way.

## In the window

The Buildbarn
[storage format cutover](migrate-to-1.0.0-buildbarn.md#storage-format-cutover-and-rollback)
is the spine of the window. The other two charts are upgraded while Buildbarn
is stopped:

1. Stop builds, pause the worker pools, stop the Buildbarn clients, then stop
   storage (cutover steps 2 and 3).
2. Snapshot the old cache if a rollback is required, and retire the old cache
   files (cutover steps 3 and 4).
3. Apply the BB Worker Operator `1.0.0` CRD, then upgrade the operator chart;
   see
   [Upgrading to 1.0.0](migrate-to-1.0.0-bb-worker-operator.md#upgrading-to-100).
4. Upgrade Hermetiq; see
   [Upgrade](migrate-to-1.0.0-hermetiq.md#upgrade).
5. Update `RbeWorker` image pins and custom worker configuration, then upgrade
   Buildbarn with storage first, restore its clients, and resume the worker
   pools (cutover step 5).
6. Verify each rollout, then an end-to-end build (cutover step 6), and tell
   build users what to expect; see
   [What build clients see](migrate-to-1.0.0-buildbarn.md#what-build-clients-see).

An existing Buildbarn Local SSD pool has its own procedure inside the same
window; see
[Cut-over procedure for an existing Local SSD pool](migrate-to-1.0.0-buildbarn.md#cut-over-procedure-for-an-existing-local-ssd-pool).

## Rolling back

Going back is another cold cut-over, not `helm rollback`. Buildbarn needs its
pre-CDC snapshot restored or another cache reset, the operator chart returns
to `0.3.12`, and each `RbeWorker` gets its old image pins back. Follow the
rollback part of the
[storage format cutover](migrate-to-1.0.0-buildbarn.md#storage-format-cutover-and-rollback)
and the rollback note under
[Upgrading to 1.0.0](migrate-to-1.0.0-bb-worker-operator.md#upgrading-to-100).
