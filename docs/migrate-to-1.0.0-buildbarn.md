# Migrating the Buildbarn chart to 1.0.0

This guide is for a Buildbarn release on chart `0.9.9` or earlier. A new
installation needs none of it: follow the
[chart README](../charts/buildbarn/README.md#install-prerequisites) instead. The Buildbarn
upgrade is one part of the `1.0.0` bundle cut-over; read
[Migrating to 1.0.0](migrate-to-1.0.0.md) first for the order across the
Hermetiq, BB Worker Operator and Buildbarn charts.

Chart `1.0.0` moves Buildbarn to content-defined chunking (CDC, RepMaxCDC)
storage. The new storage encoding cannot read the old CAS files, and AC, ISCC
and FSAC objects change encoding too. There is no in-place conversion and no
rolling upgrade: plan a maintenance window and fresh CDC storage, or an explicit
cold-cache reset of the existing storage. Chart `1.0.1` adds an optional
[blue-green storage procedure](#optional-blue-green-storage-with-chart-101)
that stages fresh claims before switching clients. Keep the old claims or a
consistent snapshot if you need a rollback. The chart refuses legacy files
rather than rewriting or deleting them.

The same release makes persistent indexes the default for CAS, CMS, AC, ISCC
and FSAC in both filesystem and raw-block backends, and enables ISCC and FSAC
by default. Adopt these defaults in the same window so the cache warms once.
The new encoding invalidates old contents even for an already-persistent ISCC.

## Contents

- [What changes in 1.0.0](#what-changes-in-100)
- [Upgrading configurations to CDC](#upgrading-configurations-to-cdc)
  - [What the upgrade checks cover](#what-the-upgrade-checks-cover)
- [Migrate to persistent indexes](#migrate-to-persistent-indexes)
- [Raw block stores](#raw-block-stores)
- [Optional blue-green storage with chart 1.0.1](#optional-blue-green-storage-with-chart-101)
- [Storage format cutover and rollback](#storage-format-cutover-and-rollback)
  - [What build clients see](#what-build-clients-see)
- [Cut-over procedure for an existing Local SSD pool](#cut-over-procedure-for-an-existing-local-ssd-pool)
- [Regression coverage](#regression-coverage)

## What changes in 1.0.0

### Storage format and claims

- CAS, shared CMS, AC, ISCC, and FSAC on-disk data now live under `cdc-v1/` on
  each store's existing filesystem or metadata volume. Existing data PVC names
  are preserved; persistent raw-block defaults add metadata claim templates where
  none existed before, and the default-enabled ISCC and FSAC add `iscc` and
  `fsac` claim templates to a release that ran without them. `volume-init`
  fails before modifying any volume
  while legacy `*-keys.db`, `*-blocks.db`, or `persistent_state` exist; follow
  the [cutover procedure](#storage-format-cutover-and-rollback).
- A changed claim-template list is refused before anything is applied. On a
  real `helm install` or `helm upgrade` the chart reads the live StatefulSet
  `storage` in the release namespace and fails when its `volumeClaimTemplates`
  differ from the rendered ones: a claim name added, removed or reordered, or
  `storageClassName`, `volumeMode` or the requested size changed for an
  existing name. Access modes, labels and annotations are not compared. A
  0.9.9 release on chart defaults always differs, because 1.0.0 adds the
  `iscc` and `fsac` claims. The error lists the differences and the step to
  run first, with storage stopped:
  `kubectl delete statefulset storage --namespace <namespace> --cascade=orphan`.
  Existing PersistentVolumeClaims are kept as they are; a changed class or
  size only applies to claims that do not exist yet. The check has nothing to
  compare under `helm template`, a client-side dry run, or a GitOps tool that
  renders client-side, and `helm rollback` does not run it: a rollback across
  a claim-template change needs the same StatefulSet deletion first.
  `upgradeChecks.skipStorageClaimTemplateCheck: true` turns the check off.
  Leave it `false`: without it Helm applies every other object of the release
  and then fails on the StatefulSet.
- Every store has its own `storageClassName`, and for raw-block PVCs a second
  one for its metadata claim. Setting the CAS class does not change the
  others; see [StorageClasses](../charts/buildbarn/README.md#storageclasses). In `mode: pvc` the
  install notes print `WARNING: STORAGE CLASS MISMATCH` when an enabled
  filesystem store's class differs from the CAS class, or a raw store's
  blocks class differs from its metadata class.
- `storage.persistence.cms.keyLocationMap.type` defaults to `blockDevice`
  (a file-backed index under `cdc-v1/`). On a durable filesystem, both chunks
  and mappings survive process restarts. The index defaults to
  `keyLocationMap.sizeMi: 1280`. It is sized for the smallest possible mapping
  (two chunks, 104 bytes) and not for the 512 bytes that
  `storage.keyLocationMapSizing.averageObjectSizeBytes.cms` assumes, because
  resizing it later empties the CMS. With its 1 GiB blocks file, shared CMS
  adds 2304 MiB to the CAS filesystem or the raw CAS metadata volume; a
  dedicated filesystem CMS claim defaults to `4Gi`. Explicit `inMemory` CMS
  and raw CAS devices without a metadata filesystem retain their documented
  ephemeral behavior. An `emptyDir` still disappears when its Pod is replaced.
- `storage.persistence.mode: emptyDir` needs an `emptyDir.sizeLimit` for every
  enabled filesystem store. ISCC and FSAC are enabled by default, so values
  that only set limits for CAS and AC no longer render: set both limits or
  disable the stores.
- `storage.persistence.mode: hostPath` has two new refusals. A raw store's
  `blockDevice.metadata.hostPath.type` now defaults to `Directory` for all
  five stores (it was `DirectoryOrCreate`): the node directory must already
  exist, so a missing metadata mount fails the pod instead of being created on
  the boot disk. And an enabled filesystem ISCC or FSAC whose `hostPath.path`
  is still the chart default fails the render when CAS is a raw block device
  or `cas.hostPath.path` is not the chart default: give the store a path next
  to the other stores, or set its `enabled: false`.
- `helm upgrade --reuse-values` cannot be used for the 0.9.9 to 1.0.0
  upgrade. Helm then replaces the new chart's defaults with the values
  computed for the old release, so every key 1.0.0 introduced is missing and
  the render fails with errors that do not mention the flag. Pass your
  complete values files instead.

### Images and configuration text

- The release's own images must be CDC builds. `images.storage`,
  `images.scheduler`, `images.worker` and `images.runnerInstaller`, plus
  `images.remoteAsset` and `images.portal` when those components are enabled,
  fail the render when their tag carries an upstream date stamp before
  `20261102`. `images.browser` is not checked: bb-browser is intentionally
  still a pre-CDC binary. The check reads the tag only. A tag without an
  upstream date stamp (a re-tagged mirror), a digest-only reference, and a
  `digest` override left under the chart's default tag cannot be classified
  and are accepted, so check any such pin yourself before the upgrade.
- `scheduler.handover.enabled` and `scheduler.configurationReloadInterval`
  fail the render unless `scheduler.handover.cdcCompatibleFork` is `true`.
  Turning both off is not enough while `images.scheduler` still pins a fork
  image built without CDC support: remove that repository, tag or digest
  override too. See
  [Optional configuration reload and scheduler handover](../charts/buildbarn/README.md#optional-configuration-reload-and-scheduler-handover).
- `configOverrides`, `scheduler.actionRouter.custom`, and worker ConfigMaps
  are read as text for fields the CDC binaries reject; nothing is evaluated.
  A field is recognised bare or quoted and followed by `:`, `::` or `+:`.
  Block comments, `//` comments and whole-line `#` comments are removed
  first.
- Workers using custom ConfigMaps are checked through their actual CRD
  references and projected keys. A ConfigMap in the release namespace that no
  `RbeWorker` references is still read when its name ends in `-worker-config`
  or it carries the `hermetiq.com/worker-pool` label, unless an `RbeWorker`
  owns it; the error then says which of the two selected it. Rename such a
  ConfigMap or keep it in another namespace if it is not a worker
  configuration, for example a backup copy. ConfigMaps rendered by this
  release through `extraObjects` are read in their rendered form, including
  every document of a multi-document entry and the items of a `kind: List`.
  Live `RbeWorker` image pins, and the `workerImage` and
  `runnerInstallerImage` defaults of a referenced ConfigMap, fail under the
  same date rule and with the same limits as the release images. Stage
  existing image defaults before removing old CR image pins; see the
  [operator migration guide](migrate-to-1.0.0-bb-worker-operator.md#upgrading-to-100).

### Other components

- The worker operator and Hermetiq are not checked. Upgrade both to `1.0.0`
  in the same window as this chart. bb-worker-operator `1.0.0` generates CDC
  worker configuration only, and an older operator generates pre-CDC
  configuration that the CDC `bb-worker` rejects, so worker pools crash-loop
  until the operator matches. Hermetiq `1.0.0` reads and validates Buildbarn
  configuration in the CDC schema only. See the
  [supported chart bundle](../README.md#supported-chart-bundle).
- The checks that read the cluster have a switch under `upgradeChecks` for
  installs they cannot serve: `skipWorkerChecks` when the account running
  Helm may not list `RbeWorker` objects or ConfigMaps (Helm then stops with a
  `forbidden` error), and `skipConfigTextCheck` when the text scan refuses
  configuration that is valid CDC. `values.yaml` says what to verify by hand
  before setting one.
- `bb-browser` is still a pre-CDC binary and now reads CAS through the
  frontend on port `8980`, which reassembles multi-chunk blobs for it. It
  dials `frontend-internal:8980` by default and `frontend-grpc:8980` when
  `frontend.internalService.enabled` is `false`; it still reads the Action
  Cache from the storage shards on `:8981`. This is a new in-cluster hop: a
  NetworkPolicy that selects the frontend pods must admit the browser pods,
  or Browser pages that show commands, directories, files and logs time out.
- When `bb-browser` is enabled (`browser.replicas > 0`) and the cache proxy
  enforces authentication (`frontend.grpcCacheProxy.enforceAuth=true`),
  `frontend.internalService.enabled=true` is required because `bb-browser`
  has no proxy credentials. With the cache proxy enabled, `enforceAuth=false`
  and the internal Service disabled, the render succeeds and Browser's CAS
  reads pass through the proxy sidecar like any other client's.
- `portal.bes.enableGraphqlPlayground: false` no longer disables anything.
  The pinned bb-portal serves the GraphQL playground whenever the GraphQL API
  is configured, and the chart always configures it; see
  [bb-portal](../charts/buildbarn/README.md#bb-portal).
- Dashboards distinguish CDC chunk storage (`cs`) and chunk mappings (`cms`),
  while continuing to display old `cas` metrics during a mixed rollout.
  Removed invalid-put metrics are retired rather than renamed to nonexistent
  series. Separate CMS retention/index views show mapping pressure even when
  chunk capacity is healthy.

## Upgrading configurations to CDC

The chart's templates generate CDC configuration. Existing data still requires
the [storage cutover](#storage-format-cutover-and-rollback), including installs
configured only through values. Raw Jsonnet also needs edits: `configOverrides`,
custom common libraries, `scheduler.actionRouter.custom`, and the ConfigMaps
referenced by `RbeWorker.spec.config.files` or `config.generated`. The chart
refuses the upgrade when it finds pre-CDC configuration in any of them;
[What the upgrade checks cover](#what-the-upgrade-checks-cover) lists what it
reads and what it cannot detect. Migrate custom files by hand before
upgrading, using this table:

| Old (pre-CDC) | New (CDC) |
| --- | --- |
| `contentAddressableStorage: { ... }` at the top level of `storage.jsonnet` or `frontend.jsonnet` | `contentAddressableStorageServer: { contentAddressableStorage: { chunkStorage: ..., chunkMappingStorage: ..., cdcParameterCache: ... }, getAuthorizer, putAuthorizer, findMissingAuthorizer, maximumChunkCount: 100000 }` (and `chunkingParameters` inside `storage.jsonnet`'s `chunkStorage.local`) |
| `portal.jsonnet` (`contentAddressableStorage`, `besServiceConfiguration.database`, `databaseCleanupConfiguration`, `instanceNameAuthorizer`, `enableGraphqlPlayground`, flat `actionCache`/ISCC/FSAC) | `contentAddressableStorageServer: { contentAddressableStorage: ..., readAuthorizer: ... }`, top-level `database` + `cleanupConfiguration`, `graphqlApiServiceConfiguration`, `blobstoreServiceConfiguration: {}`, per-service `readAuthorizer`/`publishAuthorizer`, and wrapped `{ backend, readAuthorizer }` for `actionCache`, `initialSizeClassCache`, and `fileSystemAccessCache` |
| `browser.jsonnet` (`blobstore: common.blobstore`) | `bb-browser` remains pre-CDC: set `blobstore: { contentAddressableStorage: { grpc: { client: { address: 'frontend-internal:8980' } } }, actionCache: common.blobstore.actionCache }` |
| Single-store `contentAddressableStorage` (in `common.libsonnet`'s `blobstore.contentAddressableStorage`, or top-level `contentAddressableStorage` in `scheduler.jsonnet` / `asset.jsonnet`) | `{ chunkStorage: <the old backend>, chunkMappingStorage: { chunkMappingValidating: { backend: ... } }, cdcParameterCache: { cacheSize: 1000, cacheDuration: '3600s', cacheReplacementPolicy: 'LEAST_RECENTLY_USED' } }` |
| `legacyContentAddressableStorage` (fork `scheduler.jsonnet`) | `contentAddressableStorage` with the CDC `{ chunkStorage, chunkMappingStorage, cdcParameterCache }` shape |
| `dataIntegrityValidationCache: { ... }` | Remove it. Chunks are validated individually, and client-side chunk mappings by `chunkMappingValidating`. |
| `keyLocationMapInMemory` or `keyLocationMapOnBlockDevice` | `keyLocationMap: { inMemory: ... }` or `keyLocationMap: { onBlockDevice: ... }` |
| `keyLocationMapMaximumGetAttempts`, `keyLocationMapMaximumPutAttempts` | `maximumGetAttempts` and `maximumPutAttempts` inside `keyLocationMap` |
| `browserUrl` (worker, noop worker) | `portalUrl`; in `scheduler.jsonnet`, `deprecatedPortalUrl` |
| `adminHttpServers` (scheduler) | `deprecatedAdminHttpServers` |
| `adminRoutePrefix` (scheduler) | `deprecatedAdminRoutePrefix` (or remove it) |
| `zstdPool` (scheduler, worker, noop worker, remote asset) | Remove it (still supported by `bb-storage` and `bb-portal`). |

Keep a backup of your values and custom configs before editing. Include the worker ConfigMaps that pools mount: an `RbeWorker` references them by name and does not contain their files. In custom storage configuration, put every store path (CAS, shared CMS, AC, ISCC, FSAC) under `cdc-v1/` on its parent mount, and follow the explicit reset below so legacy files are retired before CDC storage starts. To check the result, run the upgrade with `--dry-run=server`: it runs the chart's checks, including the ones that read the cluster, and applies nothing. Those checks read configuration as text; they do not prove that a component starts.

Fresh CDC storage starts empty. The optional blue-green procedure can prewarm
selected objects through the APIs before cutover. An earlier lab run reused
legacy files and observed 0/2571 hits on the first build and 2571/2571 on the
repeat, with a data-integrity error logged once per node. That experiment does
not establish a safe in-place upgrade: the chart refuses legacy files and
requires fresh storage or the explicit
[storage cutover](#storage-format-cutover-and-rollback) below. Budget for cache
refill; do not bypass the guard based on those lab results.

The worker in `RbeWorker` and the image pins also move together. A pinned pre-CDC `bb-worker` or `bb-runner-installer` image rejects the CDC worker config, so remove the pin (the operator then uses the images the chart publishes) or update it to the CDC release in the same change. The same applies to the release's own `images.*` values: remove `tag` and `digest` overrides carried over from the old release.

`bb-browser` also changes its network path. It is still a pre-CDC binary, so it no longer reads the CAS from the storage shards: it reads it through the frontend on port 8980, at `frontend-internal:8980`, or at `frontend-grpc:8980` when `frontend.internalService.enabled` is `false`. It still reads the Action Cache from storage on 8981. If your own NetworkPolicy restricts ingress to the frontend pods, admit the `app: browser` pods on TCP 8980 before upgrading, or Browser pages that load CAS content time out.

### What the upgrade checks cover

`validate.yaml` refuses a release that would start pre-CDC binaries on CDC configuration, or CDC binaries on pre-CDC configuration. The checks read text, tags and annotations. Passing them does not prove that a configuration loads.

**Configuration text.** The chart reads Jsonnet as text. Nothing is evaluated and imports are not followed. It reads:

- every `configOverrides` entry and `scheduler.actionRouter.custom`;
- the keys that an `RbeWorker` in the release namespace references through `spec.config.files` (`configMapName`, `items`; every key when `items` is unset) or `spec.config.generated` (`commonConfigMapName`, `commonItems`), from the live ConfigMap. When the release itself renders that ConfigMap through `extraObjects`, the rendered copy is read instead, since the upgrade replaces the live one: every YAML document of the entry, and every item of a `List`;
- every key of any other ConfigMap in the release namespace whose name ends in `-worker-config` or that carries the `hermetiq.com/worker-pool` label, unless an `RbeWorker` owns it. No `RbeWorker` has to reference it. A backup copy of a pre-CDC worker configuration with such a name or label blocks this upgrade and every later one: rename it, delete it, or keep it in another namespace. The error says when a ConfigMap was selected this way. The chart's own `buildbarn-config` and `buildbarn-worker-config` are not read.

A removed field is recognised bare or quoted, followed by `:`, `::` or `+:`, after block comments, `//` comments and lines starting with `#` are removed. A `contentAddressableStorage` definition counts as CDC when the file sets `chunkStorage`, `chunkMappingStorage`, `chunkMappingCache`, `cdcParameterCache` or `chunkCache`, or refers to `common.blobstore.contentAddressableStorage`.

What it cannot do:

- It does not see computed keys such as `['zstdPool']:`, fields assembled by code, or anything behind an `import`.
- `//` inside a string hides the rest of that line, so a removed field later on the line is missed. A `#` after other text is not treated as a comment, so a field name there is matched.
- `browserUrl` is matched as a word anywhere outside a comment, including inside a string.
- Setting one of the CDC fields anywhere in a file, or mentioning `common.blobstore.contentAddressableStorage`, exempts the whole file from the single-store check, even around a pre-CDC decorator. Delegating through an import alias other than `common` is refused as pre-CDC.
- An `RbeWorker` that references a missing ConfigMap fails the upgrade even at zero replicas. `RbeWorker` resources outside the release namespace are not read.

**Images.** The chart refuses a tag that carries an upstream date stamp before `20261102` on `images.storage`, `images.scheduler`, `images.worker` and `images.runnerInstaller`, on `images.remoteAsset` and `images.portal` when those components are enabled, and on a live `RbeWorker`'s `spec.images.worker` or `spec.images.runnerInstaller`, including the `workerImage` and `runnerInstallerImage` defaults of its referenced ConfigMap. `images.browser` is not checked, because `bb-browser` stays pre-CDC on purpose. Only the upstream `YYYYMMDDThhmmssZ-<commit>` tag form can be classified. A re-tagged mirror image, a digest-only reference, and a stale `digest` override left next to a new tag are all accepted, for the release's images and for `RbeWorker` pins alike. Check those by hand.

**Scheduler fork features.** `scheduler.handover.enabled` and `scheduler.configurationReloadInterval` are refused unless the selected fork implements CDC and those features (`scheduler.handover.cdcCompatibleFork: true`, with a non-upstream `images.scheduler.repository` and no pinned upstream `images.scheduler.digest`). Turning both off for the upgrade is not enough while `images.scheduler` still pins a fork built without CDC support: that scheduler rejects the CDC configuration with or without the features, so remove its `repository`, `tag` and `digest` overrides as well. The chart emits CDC `contentAddressableStorage` in every mode.

**Cluster state.** The remaining checks read live objects with `lookup`:

- The worker operator and Hermetiq are not checked. bb-worker-operator `1.0.0` generates CDC worker configuration only and Hermetiq `1.0.0` reads the CDC schema only; upgrade both in the same window as this chart. With an older operator the worker pools crash-loop on pre-CDC configuration until it is upgraded.
- The live `RbeWorker` pins and worker ConfigMaps described above.
- The live `storage` StatefulSet has the same `volumeClaimTemplates` as the release renders; see step 1 of the [storage cutover](#storage-format-cutover-and-rollback).

These checks run on `helm install` as well as `helm upgrade`. When the account running Helm may not list `RbeWorker` objects or ConfigMaps, Helm stops with a `forbidden` error; `upgradeChecks.skipWorkerChecks` turns the worker checks off, and `upgradeChecks.skipConfigTextCheck` turns off the text scan when it refuses configuration that is valid CDC. Verify by hand what a skipped check would have verified. They are skipped wherever `lookup` returns nothing: offline `helm template`, client-side dry runs, and GitOps tools that render client-side (Argo CD renders with `helm template`). Check those configurations against this section by hand, or run the real command with `--dry-run=server`, which performs the lookups and applies nothing.

## Migrate to persistent indexes

Persistent indexes are now the chart default for all five stores in both
filesystem and raw-block backends. The chart keeps existing sizes, block
geometry, paths, and memory-resource defaults; it does not migrate old contents or
provision missing hostPath filesystems automatically.

For pre-CDC deployments, use one coordinated maintenance window for the
[storage format cutover](#storage-format-cutover-and-rollback)
and these new defaults. Stop clients and storage, reset all old stores, prepare
metadata volumes and claim templates, and start CDC with persistent indexes.
That format change invalidates even previously persistent ISCC history; keeping
old PVCs cannot avoid the cold start. The steps below are the capacity and values
checklist for that cutover. Only deployments already on CDC should use the
same-format rollout in step 5 instead of the complete cutover runbook.

Remove old explicit `inMemory` overrides, or apply
[`custom-values/buildbarn-values-persistent.yaml`](../custom-values/buildbarn-values-persistent.yaml)
after deployment values to override them. The profile only changes index types;
it preserves ISCC/FSAC enable flags and does not change backends, volume mode,
block geometry, index sizes, paths, StorageClasses, or resources. CMS retains its configured
backend, including the default `sharedCas`. Within CDC, already-persistent
stores keep their paths and sizes. To deliberately retain volatile indexes, use
the [ephemeral opt-out](buildbarn-storage-operations.md#explicit-ephemeral-opt-out) instead.

1. **Capture the current configuration.** Save the current release values and
   rendered manifest, and retain your deployment values file. Inspect
   `helm get values buildbarn --namespace hermetiq --all` for inherited settings.
   `--reuse-values` cannot render 1.0.0. It substitutes the old chart's
   defaults for the new ones, so every key added in 1.0.0 is missing and the
   render stops on an error that does not name the flag, such as
   `storage.persistence.cms.backend must be one of: sharedCas, filesystem,
   blockDevice`. Nothing is applied. Pass the complete values files, or use
   `helm upgrade --reset-then-reuse-values` when carrying forward the
   release's overrides: it starts with new chart defaults, then applies stored
   explicit values and the new command-line overrides. It still retains explicit
   `inMemory` settings; remove or override them deliberately. It also retains
   every value an earlier upgrade passed with `--set`. Replica counts held at
   `0` during a cut-over are stored that way and are carried into each later
   upgrade until an explicit value replaces them, so pass the real counts when
   restoring clients and check `helm get values buildbarn --namespace hermetiq`
   for leftovers. Do not combine it with `--reuse-values` or `--reset-values`,
   which take precedence. See the
   [Helm upgrade reference](https://helm.sh/docs/helm/helm_upgrade/). An
   upgrade flag alone cannot migrate volumes or repair stale checkpoints. Check for
   `configOverrides` that replace the generated storage config. If the deployment
   already uses CDC and existing persistent contents must be retained, keep its
   shard count, backend, block size, and index size unchanged. Compare the
   rendered sizes with the running configuration instead of assuming a default
   did not move: `storage.persistence.cms.keyLocationMap.sizeMi` now defaults to
   1280, and taking a changed index default resizes that index and empties its
   store unless the old value is pinned. The pre-CDC cutover is already cold, so
   reviewed capacity changes can share that maintenance window. Step 4 gives the
   commands that show the chart's guards and NOTES warnings before anything is
   applied.

2. **Check capacity for every enabled store.** A disk index uses 66 bytes per
   record, so `index MiB >= desired entries × 66 / 1048576`, rounded up. Continue
   sizing entries against blob capacity, not only the current working set.
   `keyLocationMap.entries` and `keyLocationMapInMemoryEntries` stop controlling
   capacity once the index moves to a file; review `keyLocationMap.sizeMi` or
   `blockDevice.metadata.keyLocationMapSizeMi` instead. The chart's sizing guard
   uses the same 66-byte disk-record size; the roughly 64-byte in-memory entry
   estimate does not size file indexes. Keep space for state and filesystem
   metadata. Include shared CMS in the CAS filesystem or metadata-volume budget:
   its defaults add 1Gi of blocks and a 1280Mi index (2304Mi). The default
   1000Gi CAS claim and the default 10Gi raw CAS metadata claim both hold it; a
   smaller customized claim may not, and the render then fails. A dedicated
   filesystem CMS claim defaults to 4Gi for the same two files. For example,
   the default filesystem AC uses 10Gi blocks plus a 1344Mi index inside a 12Gi
   claim; a customized 11Gi blocks file would not fit. These checks read the
   values, not the live claim: an existing claim keeps the size it was created
   with, so compare the output of `kubectl get pvc --namespace hermetiq` with
   the rendered sizes and expand a claim that is too small before starting
   storage. Budget page-cache memory and sync I/O too: the raw-CAS file
   default is 7360Mi, much larger than the former default 24M-entry RAM map
   (~1.43GiB). The five default file indexes total 10304Mi (10.06GiB) on
   filesystem backends (CAS 7168, CMS 1280, AC 1344, ISCC 256, FSAC 256) and
   11008Mi (10.75GiB) with raw CAS/AC/ISCC/FSAC and shared CMS (CAS 7360, CMS
   1280, AC 1344, ISCC 512, FSAC 512), before CMS blocks, Go heap, and I/O
   buffers. The unchanged 4Gi memory request does not reserve that working set:
   size requests and limits for the expected page cache and workload. The
   profile deliberately does not resize indexes or adjust resource limits.

   The sizing guard divides usable bytes by
   `storage.keyLocationMapSizing.averageObjectSizeBytes`, which is the size of
   one stored record. Do not measure it from
   `buildbarn_blobstore_blob_access_operations_blob_size_bytes`. On the CDC
   image that histogram records the size named in the request digest, not the
   stored record: the uncompressed chunk for `storage_type="cs"` (the stored
   chunk is ZSTD-compressed and smaller), the whole blob for `cms`, and the size
   in the digest that keys the record for `ac`, `iscc`, and `fsac`. For CAS, AC,
   ISCC, and FSAC use, per `storage_type` on the storage pods,
   `buildbarn_blobstore_flat_blob_access_refreshes_size_bytes_sum` divided by
   `buildbarn_blobstore_flat_blob_access_refreshes_blobs_sum`. Both stay at zero
   until data has aged into the old blocks, so they cannot confirm sizing right
   after a cold cutover or a reset. For CMS use `32 + 36 × (mean blob size / mean
   chunk size)` bytes per mapping, never below 104; the comment above
   `storage.keyLocationMapSizing` in the chart's `values.yaml` gives the inputs.
   The default CMS index is sized for that 104-byte floor rather than for the
   guard's 512-byte default, because resizing it later empties the CMS. After
   the cutover, the dropped-put and exhausted-get counters under
   [Monitoring](buildbarn-storage-operations.md#monitoring) are the check that an index is large enough.

3. **Prepare storage according to the existing backend.**

   | Existing store | Preparation and migration |
   |---|---|
   | Filesystem + PVC | Ensure the existing claim has room for the index and state at the paths listed below, and on the CAS claim for the shared CMS files; no new claim is needed for an already-enabled store. Keep its blocks file and geometry unchanged. ISCC and FSAC are now enabled, so unless values set `enabled: false` the StatefulSet gains two claim templates, `iscc` (2Gi) and `fsac` (6Gi), one claim each per replica. Their StorageClass defaults to `premium-rwo` whatever class CAS uses: set `storage.persistence.iscc.storageClassName` and `storage.persistence.fsac.storageClassName` before the claims are created, because a claim keeps the class it was created with. NOTES prints `WARNING: STORAGE CLASS MISMATCH` when a filesystem store's class differs from the CAS class. The added templates require [StatefulSet recreation](buildbarn-storage-operations.md#recreate-the-storage-statefulset). |
   | Filesystem + hostPath | Ensure free space in the existing `hostPath.path`; recovery remains limited to that retained node and filesystem. ISCC and FSAC are now enabled and each mounts its own `hostPath.path`. Give both an explicit path next to the other stores, or set `enabled: false`. When CAS is a raw block device or `cas.hostPath.path` is not the chart default, the render refuses an ISCC or FSAC still on the chart default path (`/mnt/stateful_partition/kube-ephemeral-ssd/buildbarn-storage/<store>`): where that is not a mounted SSD, the kubelet creates the directory on the node boot disk. AC is not checked; set its path yourself. |
   | Filesystem + emptyDir | Ensure `emptyDir.sizeLimit` fits the blocks and index. ISCC and FSAC are now enabled, and each needs `storage.persistence.<store>.emptyDir.sizeLimit` (their PVC defaults are 2Gi and 6Gi) or `enabled: false`; the render fails otherwise. Container restarts may recover, but replacing the pod still loses the store. |
   | Raw block + PVC | Set each store's `blockDevice.metadata.storageClassName` and `blockDevice.metadata.size`. The metadata class defaults to `premium-rwo` whatever class the blocks use. For node-local blocks set it to the blocks' local StorageClass/device class, never network metadata: TopoLVM deletes only its own claims when a node is deleted, so a metadata claim on another class survives and is reattached to new, blank blocks. NOTES prints `WARNING: STORAGE CLASS MISMATCH` when the two classes differ. Adding `<store>-meta` requires [StatefulSet recreation](buildbarn-storage-operations.md#recreate-the-storage-statefulset). Reuse blocks only with fresh metadata for the cold cutover; when discarding a store, reset/delete its blocks and metadata claims together. |
   | Raw block + hostPath | Supply a retained filesystem `blockDevice.metadata.hostPath.path` for every enabled raw store. The directory must already exist: `blockDevice.metadata.hostPath.type` now defaults to `Directory` (it was `DirectoryOrCreate`), so a missing directory fails the volume mount and the pod does not start, where before the kubelet created it on the boot disk. This adds pod volumes, not PVC templates, so no StatefulSet recreation is needed. Stores left on the filesystem backend follow the "Filesystem + hostPath" row. |

   CAS uses `cdc-v1/keys.db`; AC/ISCC/FSAC use
   `cdc-v1/<store>-keys.db`, with `cdc-v1/persistent_state/` alongside each map.
   Shared CMS uses `cdc-v1/cms-{blocks,keys}.db` and
   `cdc-v1/cms_persistent_state/` on the CAS filesystem or metadata volume; it
   needs no separate claim or hostPath. Dedicated CMS uses `cms-keys.db` and
   `persistent_state/` directly under `/storage-cms` or `/storage-cms-meta`, and
   requires the same capacity and metadata review as the other stores.

   The bundled Local SSD layout provides the raw hostPath metadata directories.
   The provisioner in
   [`custom-values/partition-ephemeral-disks-daemonset.yaml`](../custom-values/partition-ephemeral-disks-daemonset.yaml)
   creates a 16Gi metadata filesystem on the same SSDs as the data LVs, mounts
   it at `/mnt/stateful_partition/buildbarn-local-ssd/metadata`, creates the
   `cas`, `ac`, `iscc`, and `fsac` directories in it, and labels the node
   `hermetiq/ephemeral-lvm=ready` only after verifying the mount. The overlay
   [`custom-values/buildbarn-values-local-ssd-block.yaml`](../custom-values/buildbarn-values-local-ssd-block.yaml)
   schedules storage on that label and sets these paths:

   ```yaml
   storage:
     persistence:
       cas:
         blockDevice:
           metadata:
             hostPath: { path: /mnt/stateful_partition/buildbarn-local-ssd/metadata/cas, type: Directory }
       ac:
         blockDevice:
           metadata:
             hostPath: { path: /mnt/stateful_partition/buildbarn-local-ssd/metadata/ac, type: Directory }
       iscc:
         blockDevice:
           metadata:
             hostPath: { path: /mnt/stateful_partition/buildbarn-local-ssd/metadata/iscc, type: Directory }
       fsac:
         blockDevice:
           metadata:
             hostPath: { path: /mnt/stateful_partition/buildbarn-local-ssd/metadata/fsac, type: Directory }
   ```

   A Local SSD pool provisioned before this layout has no metadata LV and
   cannot gain one in place. Follow the
   [cut-over procedure for an existing Local SSD pool](#cut-over-procedure-for-an-existing-local-ssd-pool).

   With your own layout, provide the same things yourself: a filesystem on the
   same storage as the blocks, one existing directory per raw store inside it,
   and a scheduling gate on the verified mount. Reset the matching metadata
   whenever a data device is recreated. `Directory` avoids silently creating
   absent paths on the boot disk; it does not itself verify mount identity, so
   point each path at a directory inside the mounted filesystem, not at the
   mountpoint, which exists on the boot disk whether or not anything is mounted.
   Shared CMS uses CAS metadata; dedicated raw CMS needs its own directory too.

   `metadata.size` provisions a PVC only in PVC mode; it does not reserve or
   enforce hostPath space. Node-local metadata cannot protect lost Local SSD
   blocks. Surviving node replacement requires durable storage for both. The new
   enabled defaults add ISCC/FSAC data claims unless existing values explicitly
   disable them. Plan these claims in the same cutover; switching shared CMS
   to a dedicated volume also adds claim templates.

4. **Render and inspect before upgrading.** From the repository root, apply the
   profile after deployment values, and any reviewed sizing/path overrides last:

   ```bash
   helm template buildbarn ./charts/buildbarn --namespace hermetiq \
     -f deployment-values.yaml \
     -f custom-values/buildbarn-values-persistent.yaml \
     -f persistence-overrides.yaml \
     --set storage.keyLocationMapSizing.validate=true > buildbarn-persistent-rendered.yaml
   ```

   Use an empty `persistence-overrides.yaml` or omit that argument if no overrides
   are needed. Compare with the saved manifest: check file-index paths,
   `persistent.stateDirectoryPath`, volume mounts, init permissions, and expected
   claim additions. Verify block sizes, device paths, shard count, and unrelated
   settings are unchanged. A later `inMemory` override intentionally opts that
   store back out.

   `helm template` runs the chart's render guards, but it prints no NOTES and
   cannot see the cluster. `storage.keyLocationMapSizing.validate=true` makes
   an undersized index a render error that shows the arithmetic; with the
   default `false` the same finding is only a `WARNING: STORAGE INDEX CAPACITY`
   line in NOTES. Keep the setting in your values once the render passes.
   `helm lint` is not a substitute for the render: it logs the chart's `fail`
   guards as informational messages and still reports the chart as passing.

   Then run the upgrade command you intend to use, with the same values files
   and flags, as a server-side dry run against the cluster:

   ```bash
   helm upgrade buildbarn ./charts/buildbarn --namespace hermetiq --dry-run=server \
     -f deployment-values.yaml \
     -f custom-values/buildbarn-values-persistent.yaml \
     -f persistence-overrides.yaml
   ```

   It applies nothing. It runs the `lookup` checks an offline render skips: live `RbeWorker` and worker ConfigMap contents,
   and the comparison of the live `storage` StatefulSet's claim templates with
   the rendered ones (see
   [Recreate the Storage StatefulSet](buildbarn-storage-operations.md#recreate-the-storage-statefulset)). It
   also prints NOTES at the end of its output. Read the storage lines there:
   `WARNING: VOLATILE STORAGE STORES`, `WARNING: STORAGE INDEX CAPACITY`,
   `WARNING: STORAGE CLASS MISMATCH`, and the `emptyDir` warning. A bare
   `--dry-run` is a client-side render and skips the same checks. A GitOps
   tool that renders with `helm template` runs neither the lookup checks nor
   NOTES.

5. **Perform the reviewed migration.** For pre-CDC, use the coordinated
   [cutover runbook](#storage-format-cutover-and-rollback),
   including the stopped-StatefulSet recreation when claims change. For an
   already-CDC deployment, schedule a cold-cache window, because
   each previously volatile store starts empty on the first conversion. Drain
   builds first; if CAS or CMS is reset, restart frontends before resuming clients
   so stale positive existence-cache entries cannot hide missing blobs. When
   the claim templates change (raw PVC stores gaining `<store>-meta` claims,
   ISCC or FSAC being enabled, a dedicated CMS), follow
   [Recreate the Storage StatefulSet](buildbarn-storage-operations.md#recreate-the-storage-statefulset) with
   storage stopped: the upgrade is refused until the old StatefulSet object is
   gone. Otherwise, use a normal upgrade with the same file order:

   ```bash
   helm upgrade buildbarn ./charts/buildbarn --namespace hermetiq --reset-then-reuse-values \
     -f deployment-values.yaml \
     -f custom-values/buildbarn-values-persistent.yaml \
     -f persistence-overrides.yaml
   ```

   Keep the reviewed values in subsequent upgrades. If older deployment files
   retain `inMemory`, keep the persistent profile after them or remove those
   overrides. Confirm healthy storage pods and successful metadata mounts, then
   verify retained history/cache entries through a controlled graceful restart
   after the store has warmed and persisted state. Allow enough termination
   grace time for the disks to sync. Abrupt failures can still lose unsynchronized
   writes as described under
   [What Survives a Restart](buildbarn-storage-operations.md#what-survives-a-restart).

## Raw block stores

A release whose raw PVC stores ran in-memory indexes on 0.9.9 (the raw default then) has no `<store>-meta` claims. Chart 1.0.0 defaults those stores to file indexes and adds a `<store>-meta` template for each, on `premium-rwo` unless you set `blockDevice.metadata.storageClassName`. Either set that class for every raw store and recreate the StatefulSet, or keep the indexes volatile by applying the [ephemeral profile](buildbarn-storage-operations.md#explicit-ephemeral-opt-out) last: with it the raw stores render the same claim templates as on 0.9.9. ISCC and FSAC are now enabled by default and add their own claims unless the release already had them or sets `enabled: false`.

A 0.9.9 install of the
[TopoLVM example](buildbarn-block-storage.md#gke-example-c-topolvm-csi) ran
in-memory indexes: four `<store>-blocks`
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


Running a pre-CDC binary over a raw block store breaks the pairing of blocks
and metadata described under
[What Survives a Restart](buildbarn-storage-operations.md#what-survives-a-restart).
Both formats write to the same device; only the index and state are kept
apart, under `cdc-v1/` on the metadata volume. After a rollback to chart 0.9.9,
or any other start of a pre-CDC image against that device, the retained
`cdc-v1/` index and state describe blocks the old binary has overwritten.
`volume-init` does not catch this: it looks for pre-CDC file names only and
reuses an existing `cdc-v1/` directory as it is. Delete
`/storage-<store>-meta/cdc-v1/` (in `hostPath` mode, `cdc-v1/` under each
`blockDevice.metadata.hostPath.path`) for every raw store, on every shard,
before starting CDC again. The CAS metadata volume also holds the shared CMS.
Filesystem stores keep a separate blocks file per format, so their `cdc-v1/`
contents stay consistent; there `volume-init` refuses to start until the files
the pre-CDC binary recreated are retired again. The rollback procedure itself
is under [Storage format cutover and rollback](#storage-format-cutover-and-rollback).

## Optional blue-green storage with chart 1.0.1

Use this procedure when you can run a second storage fleet temporarily and want
to prepare its disks before the maintenance window. It creates two permanent
Helm releases in the **same namespace**: the main application release and an
independent storage-only release. The original in-place procedure below remains
available. This approach reduces cutover work; it does not promise zero downtime
or preserve in-flight builds across the CDC client/worker upgrade.

### Stage the green storage release

Prepare the target node capacity and StorageClasses first. Review all enabled
stores' block, index and PVC sizes together with pod memory. With zonal disks,
use `WaitForFirstConsumer` and place shards across the intended nodes/zones
before claims bind. A new VM family may require a different disk class and
boot disk; that infrastructure belongs in your cluster's provisioning system.

Create a small identity overlay, `storage-green.yaml`, and combine it with your
reviewed storage sizing/scheduling values:

```yaml
namespaceOverride: hermetiq # your existing namespace
createNamespace: false
deploymentMode: storage-only
storage:
  enabled: true
  name: storage-cdc
  replicas: 3
```

```bash
helm upgrade --install buildbarn-storage-cdc oci://ghcr.io/hermetiq/buildbarn \
  --version 1.0.1 --namespace hermetiq \
  -f reviewed-storage-values.yaml -f storage-green.yaml --wait --timeout 30m
```

Use a reviewed local `charts/buildbarn` path while preparing an unreleased
chart. Storage-only mode emits the storage StatefulSet, headless Service,
`storage-cdc-config` ConfigMap and enabled storage monitoring/disruption/network
resources. It does not render application Deployments or worker ConfigMaps and
does not require the namespace's existing workers to have been upgraded first.
Choose a name not already owned by another release. Default claim names include
the StatefulSet name, so the green claims are distinct from the old claims.
Stage green storage on PVCs: storage-only mode refuses
`storage.persistence.mode=hostPath`, because hostPath stores use fixed node paths
and devices and a green pod could share a node, and its disks, with old storage.

Validate all green shards, PVC binding, disk performance, persistence after a
pod restart and storage logs before changing any production client. Clients
use per-shard DNS; changing a headless Service selector alone is not a cutover.

### Optionally prewarm a bounded working set through APIs

Never copy old blocks, indexes or checkpoints into the CDC claims. For useful
remote cache hits, copy selected ActionResults **and their complete referenced
CAS output data**. Fetch output files, stdout/stderr, output Trees and every
referenced file; include recursive Directory objects when `rootDirectoryDigest`
is present. Verify destination presence before publishing each ActionResult,
then read it through completeness checking. Missing/evicted source data should
skip that result and let a later build recreate it.

An empty AC is recoverable: Bazel executes uncached actions again. CAS data alone
does not reconstruct the action-to-output mapping. AC preservation is therefore
optional performance work, not a migration prerequisite. Preserve original
timestamps and result metadata rather than making old results appear new.

Choose known action digests from a bounded recent successful-build history;
standard REAPI has no whole-cache enumeration operation. Preserve the exact
REv2 instance name on every request. Selecting one instance's action roots
limits the working set even when the CAS shares physical data between instances.
Bound elapsed time, action count, bytes and concurrency, and distinguish copied,
skipped and failed results. Copying can run while old storage serves builds.

A temporary CDC-aware gateway configured with the **entire green shard ring**
can accept standard ByteStream uploads and produce chunks and mappings. Retain
`chunkMappingValidating` and avoid existence caching on the verification path.
Read legacy whole blobs using standard REAPI/ByteStream, not CDC chunk RPCs.
The current CDC `bb_copy` requires CDC source capabilities; pointing it directly
at a legacy server is not a conversion. Do not pair old/new shard ordinals:
chunk and mapping digests determine placement on the new ring.

Test the cross-version transfer in a staging environment, including missing
source data and a cached build/output download with the source unavailable.
Remove temporary copying resources afterward. ISCC/FSAC history can start fresh;
it need not expand this optional AC/CAS migration into an additional project.

### Cut over during the quiet window

1. Stop new builds and let important queued/executing actions finish. Pause
   **every** old worker pool at zero through its owner (for the operator, use
   `spec.autoscaling.scaledObjectAnnotations.autoscaling.keda.sh/paused-replicas:
   "0"`) and verify the worker pods have stopped. Preserve the previous pause
   settings so they can be restored after validation.
2. Upgrade the worker CRD/operator and prepare the CDC worker configuration and
   image changes described earlier in this guide. Apply worker changes while
   preserving the pause. Update explicit init-container storage addresses to
   the new shard DNS. A worker with `rolloutOnChange: false` may retain its
   configuration until recreated; image changes also trigger a rollout. Starting
   from zero ensures the new workers load the new configuration and images.
3. Verify the old StatefulSet's PVC retention policy is `Retain` for deletion
   and scaling (the Kubernetes default). Preserve old values, images and worker
   configuration for deliberate recovery. The main upgrade removes the old
   StatefulSet and its pods; PVC deletion is a separate manual cleanup task.
4. Upgrade the **main** release to `1.0.1` with the complete reviewed application
   values plus this overlay:

   ```yaml
   deploymentMode: full
   storage:
     enabled: false
     name: storage-cdc
     replicas: 3 # must match the independent storage release
   ```

   `storage.enabled: false` stops management of storage resources while retaining
   the client configuration. Frontend, scheduler, browser and generated worker
   configuration target `storage-cdc-0.storage-cdc.<namespace>:8981` and the other
   green shards. The independent release continues owning its StatefulSet and
   claims. Before applying anything, the upgrade refuses to continue if
   StatefulSet `storage-cdc` is missing, is owned by the main release, or runs a
   different number of replicas than `storage.replicas`.
   Do not run a deployment wrapper that reapplies unpaused worker CRs.
   Avoid automatic rollback during this coordinated cross-version cutover.
5. Check application readiness and the rendered client/worker addresses. Restore
   the worker pause settings, verify both custom and standard worker families,
   run a real remote build and repeat it to verify AC hits and output downloads.
   Check storage logs for checksum/decompression errors. A partially warmed
   working set will still have ordinary cache misses.
6. Delete the old PVCs manually only when satisfied with the upgrade. Continue
   managing green storage through its own release; do not reinstall it into the
   main release or attempt an implicit Helm ownership transfer.

For rollback, stop builds/workers again and restore the matching old main
release, worker operator/configuration/images and old storage claims together.
Old clients cannot use the CDC storage. Retained old claims make this deliberate
rollback possible without mounting old binaries over green data. Writes made
only to the green cache are not backfilled to the old cache.

## Storage format cutover and rollback

The pre-CDC image (`db62041`) stores raw CAS bytes and unsuffixed protobufs for AC, ISCC, and FSAC. The CDC image (`06739f2`) stores compressed CAS chunks and wraps AC, ISCC, and FSAC objects with `SHA256SuffixCoder` (a 32-byte SHA-256 suffix). Reopening old persistent indices causes decode/checksum failures that invalidate entire blocks (including newly written CDC data), and rolling back after CDC writes corrupts pre-CDC reads. This chart does not perform an in-place conversion. For deployments reusing the existing storage rather than the blue-green procedure above, the supported cutover is an explicit **cold-cache reset during a maintenance window**: every store on every shard starts empty, and builds refill the cache.
Adopt the persistent defaults in that same window, so CDC conversion and index
placement cause one cold start rather than two. ISCC and FSAC are now enabled
by default. In `mode: pvc` that adds two claim templates to every release that
did not already enable both, and the `storage` StatefulSet must then be deleted
and recreated in this window (steps 1 and 5). Keep an explicit `enabled: false`
for both stores to avoid the new claims. The persistent and ephemeral profiles
preserve these enable flags.

1. **Verify prerequisites and prepare persistent storage.**
   - Plan the worker operator and Hermetiq upgrades for this window. bb-worker-operator `1.0.0` generates CDC worker configuration only, so it is upgraded in step 5, after the worker pools are paused and before the Buildbarn upgrade (see [Upgrading to 1.0.0](migrate-to-1.0.0-bb-worker-operator.md#upgrading-to-100)). Hermetiq `1.0.0` reads the CDC schema only; upgrade it in the same window.
   - Remove pre-CDC image pins from the release values: the `tag` and `digest` overrides under `images.storage`, `images.scheduler`, `images.worker`, `images.runnerInstaller`, `images.remoteAsset` and `images.portal`. The chart refuses a date-stamped pre-CDC tag there, but it cannot classify a digest-only or re-tagged image, for these values or for `RbeWorker` pins. If you turn scheduler handover and `configurationReloadInterval` off for the upgrade, also remove the `images.scheduler` override that pins a fork built without CDC support.
   - Remove explicit `inMemory` overrides or apply the persistent profile after deployment values where the storage layout supports safe persistence. When carrying forward release overrides, use `--reset-then-reuse-values` to adopt new chart defaults, but remove/override explicit old `inMemory` values too. Do not use `--reuse-values`: it replaces the new chart's defaults with the old release's values, so every key introduced in `1.0.0` is missing and the render fails (the first error names `storage.persistence.cms.backend`). Render and lint the complete target configuration.
   - **Plan to delete and recreate the `storage` StatefulSet in step 5.** Kubernetes forbids changing `volumeClaimTemplates` in place. In `mode: pvc`, every release that did not already enable both ISCC and FSAC gains `iscc` and `fsac` claim templates, and every raw block store that moves from a RAM index to the file default gains a `<store>-meta` template. Only a release whose templates come out identical skips the recreation: one that already had both stores enabled (and file indexes on its raw stores), or one that sets `storage.persistence.iscc.enabled: false` and `storage.persistence.fsac.enabled: false`, which is the way to avoid the two new claims. `hostPath` and `emptyDir` releases have no claim templates.
   - The chart refuses the upgrade before anything is applied when the live claim templates differ from the rendered ones. For a default `0.9.9` release the error is:

     ```text
     live StatefulSet hermetiq/storage has different volumeClaimTemplates than this release renders: claim template "fsac" is added; claim template "iscc" is added. Kubernetes forbids changing volumeClaimTemplates in place, and Helm applies every other object of the release before that patch is refused, which leaves the release half-applied on the old StatefulSet. Stop storage first (scale statefulset/storage to 0 and wait for its pods to terminate), run `kubectl delete statefulset storage --namespace hermetiq --cascade=orphan`, then run this upgrade again so the StatefulSet is recreated with the rendered templates. Existing PersistentVolumeClaims are kept as they are: a changed class or size only applies to claims that do not exist yet. The same recreation is needed when rolling back to a revision whose claim templates differ; helm rollback does not run this check. Set upgradeChecks.skipStorageClaimTemplateCheck=true to skip it. See https://github.com/Hermetiq/hermetiq-k8s/blob/main/docs/buildbarn-storage-operations.md#recreate-the-storage-statefulset
     ```

     The check compares claim names and their order, `storageClassName`, `volumeMode` and requested size. Leave `upgradeChecks.skipStorageClaimTemplateCheck` at `false`. With the check skipped, or where it cannot run (a GitOps tool that renders client-side, or `helm rollback`), the ConfigMaps and client Deployments are applied first and the StatefulSet update is refused afterwards, which leaves the release half-applied.
   - Set the StorageClass of the new claims. The `iscc` and `fsac` claims and every raw `<store>-meta` claim use their own `storageClassName`, not the CAS one, and each defaults to `premium-rwo` (`storage.persistence.iscc.storageClassName`, `storage.persistence.fsac.storageClassName`, `storage.persistence.<store>.blockDevice.metadata.storageClassName`). On a cluster without that class the new claims stay Pending, `storage-0` stays Pending with them, and no other shard is created. For node-local blocks, give the metadata claim the same local class as its blocks. TopoLVM deletes only its own claims when a Node is deleted, so metadata on any other class survives while the blocks are recreated blank, and the surviving index then reports blobs that no longer exist. A real install or upgrade prints `WARNING: STORAGE CLASS MISMATCH` in its notes when a filesystem store's class differs from the CAS class, or a raw store's metadata class differs from its blocks class; `helm template` prints no notes.
   - An existing claim is reused by name (`<template>-storage-<ordinal>`, for example `cas-storage-0` or `cas-meta-storage-0`). The recreated StatefulSet creates only the claims that do not exist yet, so a class or size changed in values does not change a claim that already exists. List the claims first (`kubectl -n hermetiq get pvc`). To move metadata to another class, delete the claim itself while storage is stopped, so that it is created again from the new template. To grow a claim, expand the PVC itself and confirm its new capacity before starting storage. The chart's size checks read your values, not the live claim, and index files are sparse, so an undersized live claim starts normally and fails with `ENOSPC` as the store fills.
   - Check filesystem PVC space for every enabled store's blocks, index, and state. Shared CMS adds `1 GiB` blocks + `1280 MiB` index (`2304 MiB`) on the CAS filesystem or raw CAS metadata volume. Review index capacity and page-cache resources using the [migration checklist](#migrate-to-persistent-indexes); prepare PVC expansion where needed.
   - For raw PVC stores, prepare filesystem metadata StorageClasses and sizes for the new `<store>-meta` claims. The existing blocks claims are retained.
   - For raw local NVMe persistence, metadata must be on the same Local SSD storage with verified mount readiness and paired reset when devices/VGs are replaced. Never keep boot-disk/network metadata over lost local blocks. In `mode: hostPath` each `blockDevice.metadata.hostPath.path` must already exist on the node: its `type` now defaults to `Directory`, so a missing metadata mount fails the pod instead of being created on the boot disk. The bundled local SSD overlay uses the provisioner's same-SSD metadata LV. An existing Local SSD pool cannot be switched in place, because the new provisioner refuses a volume group laid out by the old one: follow the [cut-over procedure for an existing Local SSD pool](#cut-over-procedure-for-an-existing-local-ssd-pool). [buildbarn-gke-storage-validation.md](buildbarn-gke-storage-validation.md) is the validation procedure and record for that layout, not a migration runbook. Shared CMS is part of CAS metadata. For local PVCs, use the same local StorageClass/device class for blocks and metadata and reset/delete both claims together after loss.
   - Decide how each `RbeWorker` gets its images after the cut-over: remove `spec.images.worker` and `spec.images.runnerInstaller` to inherit the images this chart publishes in `buildbarn-worker-config`, or update the pins to CDC images. Make the change in step 5, with the pools paused.
2. **Drain clients and pause autoscalers/operator before scaling down.**
   - Stop new builds/cache clients and let active work finish. Record current replica counts and autoscaler settings (`kubectl -n hermetiq get deployments,statefulsets,scaledobjects,rbeworkers`).
   - Suspend GitOps reconciliation of the Buildbarn release and of the `RbeWorker` manifests (Argo CD automated sync and self-heal, a Flux `HelmRelease` or `Kustomization`) before any manual step, and keep it suspended until step 5 is complete. A reconciling controller reverts `kubectl scale` and the patches below, and puts back the old StatefulSet that step 5 deletes.
   - Pause each worker pool through its `RbeWorker`, not on the worker `ScaledObject` or Deployment. `bb-worker-operator` replaces every annotation on a worker `ScaledObject` with `spec.autoscaling.scaledObjectAnnotations` on each reconcile, so a `kubectl annotate` there is removed again, and it does not apply `spec.replicas` to a pool with `spec.autoscaling.enabled: true`. For each autoscaled pool:

     ```sh
     kubectl -n hermetiq patch rbeworker <pool> --type merge \
       -p '{"spec":{"autoscaling":{"scaledObjectAnnotations":{"autoscaling.keda.sh/paused-replicas":"0"}}}}'
     ```

     KEDA then scales the pool to zero and stops autoscaling it, and the pause survives the step 5 upgrade. For a pool without autoscaling, set its replicas instead:

     ```sh
     kubectl -n hermetiq patch rbeworker <pool> --type merge -p '{"spec":{"replicas":0}}'
     ```

     The operator does not write replicas for a pool with `spec.manageReplicas: false`; stop such a pool through whatever scales it. If the `RbeWorker` manifests are applied from files, make the same change there so that a later apply does not undo it.
   - Pause the chart's own frontend `ScaledObject`, which exists when `keda.enabled` and `keda.frontend.enabled` are both true, by annotating it directly. The chart renders no annotations on it, and `helm upgrade` leaves this one in place:

     ```sh
     kubectl -n hermetiq annotate scaledobject frontend autoscaling.keda.sh/paused-replicas=0 --overwrite
     ```

   - Stop the remaining clients before stopping storage:

     ```sh
     kubectl -n hermetiq scale deployment/scheduler-ubuntu22-04 deployment/frontend deployment/browser --replicas=0
     kubectl -n hermetiq scale deployment/bb-portal --replicas=0      # when portal.enabled
     kubectl -n hermetiq scale deployment/remote-asset --replicas=0   # when remoteAsset.enabled
     ```

     Wait until no worker, scheduler, frontend, browser, portal or remote-asset pod is left (`kubectl -n hermetiq get pods`). Do not mix old and CDC writers during cutover.
3. **Stop all storage pods and take consistent snapshots.**
   - Scale `statefulset/storage` to `0` and wait until all `storage-0..N-1` pods terminate cleanly (so persistent stores flush checkpoints).
   - If rollback is required, snapshot **all** durable PVCs/devices together (for persistent raw block stores, snapshot both the raw block device and its companion `-meta` PVC at the same stopped point). Retain the old Helm values, rendered configs, `RbeWorker` manifests, and image digests.
4. **Explicitly retire legacy files on every shard.**
   - For `mode: pvc`, scaling `statefulset/storage` to `0` unmounts every shard's `ReadWriteOnce` PVCs. The claims that hold legacy files are `cas-storage-<i>`, `ac-storage-<i>` and, if enabled, `iscc-storage-<i>` and `fsac-storage-<i>` for filesystem stores, and `cas-meta-storage-<i>`, `ac-meta-storage-<i>`, `iscc-meta-storage-<i>` and `fsac-meta-storage-<i>` for raw stores that already had a file index. The raw `<store>-blocks-storage-<i>` claims need no cleanup. Mount each shard's PVCs (`i = 0..replicas-1`) in a short-lived maintenance Pod/Job running as the storage UID/GID (`65534:65534` by default) to move legacy files off-volume or delete them after snapshots are verified.
   - Delete the maintenance Pods/Jobs and confirm they are gone before step 5. The claims are `ReadWriteOnce`: a claim that a maintenance Pod still mounts on another node keeps its `storage-<i>` pod from attaching the volume and starting.
   - **Ownership warning (`fsGroupChangePolicy: OnRootMismatch`):** Do **not** create directories as `root` inside a `65534`-owned PVC root; kubelet skips recursive `fsGroup` chown when the root already matches, which leaves `volume-init` unable to write. Let `volume-init` create `cdc-v1/` on startup.
   - For `mode: hostPath`, clean the configured directories on **every** storage node: `<store>.hostPath.path` for filesystem stores, and `<store>.blockDevice.metadata.hostPath.path` for raw stores that already had a file index. A raw block store has no host directory for its blocks, and one that kept its index in memory has nothing to clean at all. That does not make an existing Local SSD pool reusable: nodes laid out by the pre-`1.0.0` provisioner have no metadata filesystem and the new provisioner refuses their volume group, so follow the [cut-over procedure for an existing Local SSD pool](#cut-over-procedure-for-an-existing-local-ssd-pool) for them. For `mode: emptyDir`, pods start with empty volumes and no manual cleanup is needed.
   - Renaming legacy files elsewhere on the same PVC does **not** free capacity; new `cdc-v1/` files must fit on the volume.

   | Store & backend | Legacy entries to retire | New CDC location |
   | --- | --- | --- |
   | Filesystem CAS | `/storage-cas/cas-keys.db`, `cas-blocks.db`, `persistent_state/` | `/storage-cas/cdc-v1/{keys.db,blocks.db,persistent_state/}` + shared CMS `cdc-v1/{cms-keys.db,cms-blocks.db,cms_persistent_state/}` |
   | Raw CAS with file index | `/storage-cas-meta/cas-keys.db`, `persistent_state/` | `/storage-cas-meta/cdc-v1/{keys.db,persistent_state/}` + shared CMS under `cdc-v1/`; blocks remain on `/dev/bb/cas` |
   | Former raw CAS with in-memory index | No persistent index to retire | Raw PVC: the device is reused, and the new CAS index/state and shared CMS files start on the new `cas-meta-storage-<i>` claim. A Local SSD pool laid out by the bundled provisioner is not reused in place; see the [Local SSD cut-over procedure](#cut-over-procedure-for-an-existing-local-ssd-pool) |
   | Filesystem AC / ISCC / FSAC | `/storage-<store>/<store>-keys.db`, `<store>-blocks.db`, `persistent_state/` | `/storage-<store>/cdc-v1/{<store>-keys.db,<store>-blocks.db,persistent_state/}` |
   | Raw AC / ISCC / FSAC with file index | `/storage-<store>-meta/<store>-keys.db`, `persistent_state/` | `/storage-<store>-meta/cdc-v1/{<store>-keys.db,persistent_state/}`; blocks remain on `/dev/bb/<store>` |

   For raw block stores, resetting the metadata starts an empty logical store; a full device wipe is unnecessary. CDC writes overwrite old device contents, so rollback requires the device snapshot, not just the old metadata. `volume-init` checks **all** enabled stores before creating any `cdc-v1/` directory and never deletes, moves, or converts user data, including on repeated failed starts. Missing even one shard leaves that shard stuck in `volume-init` and blocks `FindMissingBlobs` cluster-wide.
5. **Delete the StatefulSet, then start CDC storage before clients.**
   - While storage remains at zero replicas, delete the StatefulSet:

     ```sh
     kubectl delete statefulset storage --namespace hermetiq --cascade=orphan
     ```

     Do this on every `mode: pvc` release, unless you have confirmed in step 1 that its claim templates stay identical. `hostPath` and `emptyDir` releases have nothing to delete. All existing PVCs are retained. The upgrade below creates the StatefulSet again from the rendered templates, and its pods then get the claims that do not exist yet (`iscc-storage-<i>`, `fsac-storage-<i>`, `<store>-meta-storage-<i>`) and reuse the others by name. Without the delete, the upgrade stops at the claim-template check from step 1 with nothing applied. Do not skip that check to use a failing upgrade as the preflight. For the same sequence outside this cut-over, see [Recreate the Storage StatefulSet](buildbarn-storage-operations.md#recreate-the-storage-statefulset).
   - **Do not run the cut-over upgrade with `--atomic`, `--rollback-on-failure` or `--cleanup-on-fail`, or under a GitOps controller that rolls back automatically.** An automatic rollback restarts pre-CDC binaries over volumes that were just retired or already rewritten by CDC, and `--cleanup-on-fail` deletes the StatefulSet this upgrade created. If the upgrade fails, leave the release failed, fix the cause and run the upgrade again. If you have to go back, follow the rollback procedure below.
   - While workers remain stopped, upgrade the worker operator: apply its `1.0.0` CRD (`kubectl apply --server-side -f charts/bb-worker-operator/crds/`; add `--force-conflicts` if Helm created the CRD and kubectl reports a conflict on `.spec.versions`), then upgrade the `bb-worker-operator` chart to `1.0.0`.
   - Still with workers stopped, migrate custom Jsonnet/worker ConfigMaps and update any `RbeWorker` CRs that keep explicit `spec.images.worker` / `spec.images.runnerInstaller` pins to CDC images (`>= 20261102T`) or remove the pins to inherit from `buildbarn-worker-config`. A pool without pins reports `SpecInvalid` until the upgrade below has published the image keys. The chart refuses a live pin whose tag carries a pre-CDC upstream date stamp; it does not detect a digest-only or re-tagged pre-CDC pin, so check those yourself. A worker ConfigMap the release itself renders through `extraObjects` is checked as rendered, since the upgrade replaces the live copy: migrate it in your values, not in the cluster. If an `RbeWorker` takes its image defaults from such a ConfigMap (its `commonConfigMapName`), publish `workerImage` and `runnerInstallerImage` there too.
   - Run `helm upgrade` with client replicas held at `0` (`--set frontend.replicas=0 --set scheduler.replicas=0 --set browser.replicas=0`, plus `--set portal.replicas=0` and `--set remoteAsset.replicas=0` if enabled) so storage starts first, rather than letting `helm upgrade` immediately restart clients alongside storage. `frontend.replicas` has no effect when `keda.enabled` and `keda.frontend.enabled` are both true: the frontend Deployment then renders no `replicas` field, and the frontend is held at zero by the `ScaledObject` pause from step 2.
   - Verify every `storage-0..N-1` pod completes `volume-init` and becomes Ready.
   - Restore client replicas with a second `helm upgrade` that states them. The `--set ...replicas=0` values from the hold are stored as release values. With `--reset-then-reuse-values` they are reused and win over the chart defaults, so running the same command again without the flags leaves the clients at zero and still reports success. Either pass every count explicitly (`--set scheduler.replicas=1 --set browser.replicas=1 ...`, with the counts recorded in step 2), or run both the hold and the restore from your complete values files without `--reset-then-reuse-values` or `--reuse-values`. Afterwards check that `helm get values buildbarn --namespace hermetiq` shows no `replicas: 0`.
   - Un-pause in the order frontend, then workers. Remove the frontend annotation; KEDA brings the frontend back to `keda.frontend.minReplicaCount`:

     ```sh
     kubectl -n hermetiq annotate scaledobject frontend autoscaling.keda.sh/paused-replicas-
     ```

     Then un-pause each worker pool through its `RbeWorker`, the same way it was paused in step 2, or restore `spec.replicas` for a pool without autoscaling:

     ```sh
     kubectl -n hermetiq patch rbeworker <pool> --type merge \
       -p '{"spec":{"autoscaling":{"scaledObjectAnnotations":{"autoscaling.keda.sh/paused-replicas":null}}}}'
     ```

     Resume GitOps reconciliation once the repository matches what is deployed.
   - Restart any external cache clients to discard stale existence caches, and tell build users what to expect: see [What build clients see](#what-build-clients-see).
6. **Verify end-to-end.**
   - Verify both a small blob and a multi-megabyte (> 2 MiB) composite CAS upload/read through the frontend, then gracefully restart one storage shard with the same backing volumes and read both again. For hostPath, keep the pod on the same retained node; for network PVCs, also verify volume reattachment when testing rescheduling.
   - Verify a real remote build and an Action Cache hit with retained outputs after restart. When enabled, verify ISCC scheduling history and FSAC hints are retained too. Expect old entries to miss and rebuild/reupload during the initial cutover; confirm zero ZSTD decoding or SHA-256 data-integrity errors in storage logs. Check separate CS/CMS retention and KLM panels as the cache warms.

For a deliberate cold discard of raw PVC storage, stop the shard and delete/reset
both `<store>-blocks` and `<store>-meta` together (including shared CMS in CAS
metadata). Do not recreate a missing blocks claim against an old metadata claim.
Retained claims alone are not rollback copies once their blocks have been written.

For rollback, stop all CDC clients and storage again (steps 2 and 3). Restore a consistent pre-CDC snapshot (both block devices and metadata volumes for raw block stores, across CAS and any persistent AC/ISCC/FSAC) and its matching old configurations/images before restarting. Without a snapshot, perform another explicit cold-cache reset — remove `/storage-<store>/cdc-v1/` (and `/storage-<store>-meta/cdc-v1/` for raw metadata volumes) across **all** stores and all shards before any pre-CDC image starts. There are two reasons. On filesystem stores the `cdc-v1/` files still occupy the volume, so the old `blocks.db` allocation hits `ENOSPC`. On raw block stores both formats write the same device and only the index and state are kept apart under `cdc-v1/`, so a `cdc-v1/` index left behind is reattached, on the next roll-forward, to blocks the pre-CDC binary has since rewritten: `FindMissingBlobs` reports blobs present that then fail when read, and each failed read releases that block and every older one, including data written since. **Never** point the old binary at CDC data or restore an old raw-device index over a device that CDC has modified.

`helm rollback` does none of this, and it has three problems of its own:

- It hits the claim-template rejection in reverse, and the chart's check does not run for a rollback. Where the two revisions have different claim templates, Helm reverts the ConfigMaps and client Deployments and then fails on the StatefulSet. With storage at zero replicas, run `kubectl delete statefulset storage --namespace hermetiq --cascade=orphan` again before `helm rollback`. The claims the CDC release added (`iscc-storage-<i>`, `fsac-storage-<i>`, `<store>-meta-storage-<i>`) stay behind unused until you delete them.
- It removes `workerImage` and `runnerInstallerImage` from `buildbarn-worker-config`, because the pre-CDC chart does not publish those keys. An `RbeWorker` whose pins were removed can then no longer resolve an image: the operator reports `SpecInvalid` and leaves the pool's existing Deployment, with its CDC images, as it is. Restore the pre-CDC `spec.images.worker` / `spec.images.runnerInstaller` pins.
- It does not roll back the worker operator. bb-worker-operator `1.0.0` cannot generate pre-CDC worker configuration, so roll the operator chart back to `0.3.12` as well before resuming worker pools.
- It cannot restore the storage format, or `RbeWorker` resources and custom ConfigMaps outside the release.

The same rule applies when rolling forward again. If a pre-CDC binary has run since the last CDC start, whether through a manual rollback, an automatic one or a pod started from the old StatefulSet, delete `cdc-v1/` on every store and every shard before starting CDC again. `volume-init` cannot detect this. It looks only for pre-CDC file names, and a pre-CDC raw store with an in-memory index leaves none.

An explicit ephemeral CMS remains supported, but losing its mappings on restart is intentional and tested; it is not suitable when composite CAS blobs must survive restarts. Custom `storage.jsonnet` overrides must implement an equivalent format boundary and persistence policy.

### What build clients see

The cut-over empties the Action Cache and the CAS together, so the servers hold no stale references afterwards. Clients can.

- **The first build after the cut is slow.** Nothing is cached. Every action runs again and every output is uploaded again.
- **Bazel retries on its own when it still holds references to remote outputs.** A Bazel server that was running before the cut can hold metadata for remote outputs it never downloaded. When it needs one of them, it gets a cache-eviction error internally and restarts the build automatically, up to `--experimental_remote_cache_eviction_retries` times (default 5 on supported Bazel versions). The user sees a build that starts over, not a failure. If the retries run out, the build fails with exit code 39 (`REMOTE_CACHE_EVICTED`); running it again is enough.
- **A wrapper that pins `--invocation_id` must retry itself.** Bazel generates a new invocation ID for each of those retries. A wrapper that passes its own `--invocation_id` should set the flag to `0`, check for exit code 39, and run the build again with a new ID.
- **Restart long-running clients that cache remote existence.** Anything that remembers which blobs the cache holds, such as a cache proxy or a CI daemon in front of the frontend, keeps skipping uploads of blobs that no longer exist. Restart it after step 5.

## Cut-over procedure for an existing Local SSD pool

Existing layouts that allocated the entire VG to four data LVs cannot gain the
16 GiB metadata LV in place: the group has no free extent, and the provisioner
refuses to shrink a data LV. Every node needs a new layout, on replacement VMs
or by resetting the **whole** VG in place. Do not shrink CAS or recreate one
data LV while retaining its old metadata. The CDC upgrade already requires a
cold format cut-over; do both in one outage with the procedure below.

This is the cut-over for a pool that the 0.9.9 DaemonSet provisioned (four data
LVs filling the volume group, no `meta`) and that moves to chart 1.0.0 with
the Local SSD overlay. It discards the cache. Every shard starts empty, and
nothing of the pre-CDC stores is kept.

It runs inside the
[storage-format cutover runbook](#storage-format-cutover-and-rollback).
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
     [Resetting a Local SSD node](buildbarn-block-storage.md#resetting-a-local-ssd-node) for each node.
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

## Regression coverage

The schema validation suite (`config_schema_test.sh`) uses the official protobuf
JSON parser with pinned upstream and CDC fork descriptors plus negative controls.
It needs Helm and the Python packages `PyYAML`, `jsonnet` and `protobuf`.

The storage and metrics regressions cannot be run with Helm and a bare
Python 3 alone:

| Test | Needs |
|---|---|
| `storage_migration_test.sh` | Helm, `PyYAML` |
| `storage_integration.py` | Helm, Docker, `PyYAML`, `jsonnet`, `protobuf`, `grpcio` |
| `metrics_compatibility_test.sh` | `promtool`, `PyYAML` |

```bash
bash charts/buildbarn/tests/storage_migration_test.sh
python3 charts/buildbarn/tests/storage_integration.py
bash charts/buildbarn/tests/metrics_compatibility_test.sh
```

CI runs `helm unittest` and every `tests/*_test.sh` in the chart validation
step, in a container that installs `PyYAML`, `jsonnet`, `protobuf` and
`promtool`. `tests/storage_gke_probe.py` is a manual tool that CI does not
run: it probes a disposable shard on a real cluster for the
[GKE validation runbook](buildbarn-gke-storage-validation.md).

The container tests use isolated volumes and a private Docker network in CI
(localhost-only ports when run directly). Raw-device cases require privileged
Docker helper containers to create disposable loop devices. The tests verify
that a rejected upgrade preserves old readable CAS and persistent AC data, an
explicit reset yields clean misses and reuploads (including through `frontend`),
and Action Cache completeness hides outputs lost by an explicitly ephemeral CMS.
Filesystem, raw-PVC, and raw-hostPath configurations retain CAS/CMS/AC and enabled
ISCC/FSAC entries through graceful container replacement and SIGKILL after a
checkpoint. These are Docker simulations of the storage layouts, not Kubernetes
PVC reattachment or physical NVMe/node-loss tests. A dedicated Buildkite step
runs the suite.
`metrics_compatibility_test.sh` evaluates the shipped recording rules, alerts,
and dashboard queries with `promtool` against legacy, CDC, and mixed samples.
