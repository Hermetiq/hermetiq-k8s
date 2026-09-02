# BEP NATS Stream Migration — Upgrading Hermetiq 0.4.x to 0.5.x

Hermetiq chart `0.5.x` moves BEP ingestion from a single `BEP_STREAM_<partition>` JetStream layout to dedicated per-partition streams:

| Stream | Subjects | Purpose |
|---|---|---|
| `BEP_BUILD_TOOL_<partition>` | `bep_<partition>.build_tool_v2.>`, `bep_<partition>.progress_v3.>` | Build tool events and progress output (interest retention) |
| `BEP_STREAM_<partition>` | `bep_<partition>.build_tool.>`, `bep_<partition>.progress_v2.>` | Legacy stream, kept temporarily to drain pre-upgrade messages |
| `BEP_LIFECYCLE_<partition>` | `bep_<partition>.lifecycle.>` | Build started/finished lifecycle events — **legacy `lifecycle` mode only**, see below |

All of these streams are file-backed. Memory storage is available as an opt-in for the highest ingest volumes during production sizing and tuning; it is not part of this migration.

`app.invocationStartEvent` defaults to **`build_tool`**, where invocations are created from BEP build-tool events and **no `BEP_LIFECYCLE_*` stream is provisioned or required** — the packaged `nats_streams.json` carries no lifecycle configuration. Ignore the `BEP_LIFECYCLE_*` references in the verification steps below unless you have explicitly set the legacy `app.invocationStartEvent: lifecycle` mode.

In chart `0.5.x` this migration is **automatic**: upgraded subscriber pods (`bep-nats-sub-*`) detect the legacy layout at startup and create the new streams and durable consumers (moving the lifecycle subject to `BEP_LIFECYCLE_<partition>` when running in `lifecycle` mode). Upgraded publisher pods (`bep-nats-pub`) never modify streams — they stay **unready** and reject BEP ingest with `UNAVAILABLE` until every partition's topology has been migrated, then latch ready. There are no manual NATS CLI steps and no required ordering between the publisher and subscriber rollouts.

## Requirements

1. **You must be on chart `0.4.6` before upgrading to `0.5.x`.** The automatic migration is validated against the broker and consumer state that chart `0.4.6` leaves behind. If you are on an older `0.4.x` (or earlier), first upgrade to `0.4.6` with your normal upgrade process, confirm builds ingest cleanly, and only then continue with this runbook. Do not jump from pre-`0.4.6` directly to `0.5.x`.

   ```bash
   helm ls -n hermetiq
   ```

   The `hmq` release must show chart `hermetiq-0.4.6` before you proceed.

2. **Schedule the upgrade during a period of low or no build activity.** This is the single most important step, and it is what makes the migration effectively invisible:

   - The only data at risk during the cutover is **lifecycle backlog**: legacy lifecycle messages that the old subscriber has not yet processed at the moment the subject moves. With no builds running, that backlog is zero and **nothing is lost**.
   - New publisher pods reject BEP ingest until the migration completes. With no builds running, there is nothing to reject. (During the rollout, old publisher pods keep serving whatever traffic does arrive.)
   - A Bazel invocation that does stream events during the window may report a Build Event Service upload error; the build itself is unaffected. A build whose finish event lands in skipped backlog shows as stuck/abandoned in the dashboard until the abandoned-build reaper closes it.

   The migration itself takes seconds per partition; the whole upgrade completes within a normal pod rollout (a few minutes).

3. **Do not change `app.streamPartitionCount` in the same upgrade.** The publisher validates every configured partition before serving; changing the partition count and migrating the stream layout at the same time makes failures ambiguous. Change one thing at a time.

4. **If you supply a custom `nats_streams.json`** (via `nats.streamConfig.existingConfigMap`), the migration only triggers when the resolved config uses the split layout. A pre-`0.5.x` custom file without `bep.lifecycleStreamName` keeps the deployment in the deprecated shared-lifecycle mode and **no migration happens** (the publisher logs a deprecation warning and validates the legacy layout instead). Before upgrading, pull the `0.5.x` packaged config as your new baseline, re-apply your customizations, and update your ConfigMap:

   ```bash
   helm pull oci://ghcr.io/hermetiq/hermetiq --version <target-version> --untar --untardir /tmp
   cat /tmp/hermetiq/files/config/nats_streams.json
   ```

   Installs using the chart's packaged config (the default) need no config changes.

## Step 1 — Preflight

Confirm the release is on `0.4.6` and healthy:

```bash
helm ls -n hermetiq
kubectl -n hermetiq get deploy bep-nats-pub
kubectl -n hermetiq get deploy -l app-mode=bep-nats-sub
```

All publisher and subscriber deployments should be fully ready.

Confirm build activity is quiescent — the legacy lifecycle consumers should have nothing pending. Using the `nats` CLI from the `nats-box` pod:

```bash
NATS_BOX=$(kubectl -n hermetiq get pods -l app.kubernetes.io/component=nats-box --no-headers -o custom-columns=":metadata.name")

kubectl -n hermetiq exec -it "$NATS_BOX" -- nats stream report
```

Optionally check a lifecycle consumer directly (repeat for any partition; `unprocessed` and `ack pending` should be 0 when no builds are running):

```bash
kubectl -n hermetiq exec -it "$NATS_BOX" -- nats consumer info BEP_STREAM_0 BepLifecycle-0
```

Snapshot your applied values for reference:

```bash
helm get values hmq -n hermetiq > hmq-values-before-0.5-migration.yaml
```

## Step 2 — Upgrade

Run your normal upgrade with the `0.5.x` chart version shared by the Hermetiq team:

```bash
helm upgrade --install -n hermetiq hmq \
  oci://ghcr.io/hermetiq/hermetiq --version <target-version> \
  --values hermetiq-values.yaml
```

That is the entire migration procedure. What happens during the rollout:

- The schema bootstrap hook Job runs first, as with any upgrade.
- Each new `bep-nats-sub-<partition>` pod migrates its partition at startup. Its log records the pre-migration lifecycle backlog and the subject move:

  ```text
  Legacy BEP lifecycle backlog before subject migration partition=0 stream=BEP_STREAM_0 durable=BepLifecycle-0 num_pending=0 num_ack_pending=0 ...
  Migrating BEP lifecycle subject off legacy stream partition=0 stream=BEP_STREAM_0 before_subjects=[...] after_subjects=[...] ...
  ```

- New `bep-nats-pub` pods start but stay **unready** (readiness check `nats-topology`), logging a rate-limited warning until all partitions are migrated:

  ```text
  BEP ingest waiting for subscriber-managed NATS topology: partition 7 split lifecycle topology: ...
  ```

  This is expected — it is the upgrade working as designed, not a failure. Old publisher pods continue serving until the new ones become ready. Once validation passes, each publisher logs:

  ```text
  NATS topology validation succeeded for BEP publisher ingest (partitions=16 shared_lifecycle=false); readiness latched, validation loop exiting
  ```

Watch the rollout:

```bash
kubectl -n hermetiq rollout status deploy/bep-nats-pub --timeout=10m
kubectl -n hermetiq get pods -l app-mode=bep-nats-sub
kubectl -n hermetiq logs deploy/bep-nats-pub -c bep-nats --tail=50
```

## Step 3 — Verify

Confirm the new stream layout exists for every partition:

```bash
kubectl -n hermetiq exec -it "$NATS_BOX" -- nats stream report
```

You should see `BEP_BUILD_TOOL_0..N` (N = `streamPartitionCount - 1`), each `BEP_BUILD_TOOL_<p>` carrying `BepBuildToolV2-<p>` and `BepProgressV3-<p>` consumers. `BEP_STREAM_*` still being present is normal — see [Cleanup](#cleanup). `BEP_LIFECYCLE_0..N` appears only in the legacy `app.invocationStartEvent: lifecycle` mode; its absence in the default `build_tool` mode is expected.

Spot-check one partition:

```bash
kubectl -n hermetiq exec -it "$NATS_BOX" -- nats stream info BEP_BUILD_TOOL_0
kubectl -n hermetiq exec -it "$NATS_BOX" -- nats consumer info BEP_BUILD_TOOL_0 BepBuildToolV2-0
```

Then run a small Bazel build with BEP upload enabled and confirm it appears in the Hermetiq dashboard.

## Observability

The migration emits an audit trail:

- Subscriber logs: the `Legacy BEP lifecycle backlog before subject migration ...` and `Migrating BEP lifecycle subject off legacy stream ...` lines shown above, per partition.
- Metrics (visible in Grafana via VictoriaMetrics), recorded at migration time with `partition`, `stream`, and `durable` labels:
  - `hermetiq_nats_stream_migration_legacy_lifecycle_pending`
  - `hermetiq_nats_stream_migration_legacy_lifecycle_ack_pending`

Non-zero values mean lifecycle backlog existed at cutover (i.e., builds were active). Those messages are skipped by design; any affected in-flight build is closed out by the abandoned-build reaper rather than staying stuck indefinitely. If you followed the low/no-build-activity guidance, these gauges read 0.

## Cleanup

The legacy `BEP_STREAM_*` streams remain so upgraded subscribers can drain any pre-upgrade `build_tool.>`/`progress_v2.>` messages. Legacy messages age out within the stream's retention (15 minutes by default), so shortly after the upgrade the streams are empty shells. Once each reports `Messages: 0`, remove them at your convenience:

```bash
for p in $(seq 0 <partition-count-minus-one>); do
  kubectl -n hermetiq exec -it "$NATS_BOX" -- nats stream info "BEP_STREAM_$p" || continue
  kubectl -n hermetiq exec -it "$NATS_BOX" -- nats stream rm "BEP_STREAM_$p" --force
done
```

This also removes the now-idle legacy `BepLifecycle-*`/`BepBuildTool-*` consumers. Subscribers log a warning on their next restart noting the legacy stream is gone; that is the expected end state.

## Troubleshooting

**Publisher pods stay unready for more than a few minutes.** Read the publisher warning — it names the exact partition and stream/consumer it is waiting for — then check that partition's subscriber:

```bash
kubectl -n hermetiq logs deploy/bep-nats-pub -c bep-nats --tail=20
kubectl -n hermetiq logs deploy/bep-nats-sub-<partition> --tail=50
```

Common causes:

- The subscriber rollout hasn't finished (or a subscriber pod is crash-looping for an unrelated reason such as database connectivity). The publisher recovers on its own once every subscriber partition is up.
- A custom `nats_streams.json` without `bep.lifecycleStreamName` — the deployment resolves to the deprecated shared-lifecycle mode and never migrates (see [Requirements](#requirements), item 4). The publisher logs `Resolved NATS BEP lifecycle topology is legacy shared mode ... deprecated`.
- Publisher and subscribers disagree on `app.streamPartitionCount` — the publisher waits for a partition no subscriber owns.

**A subscriber refuses to migrate a partition.** If a legacy stream's subjects were hand-edited to a broad wildcard (for example `bep_5.>`), the subscriber will not guess and logs `refusing to remove a broader subject automatically`. Restore the standard three-subject layout on that stream, or contact the Hermetiq team.

**Rolling back.** The migration is effectively one-way: once builds flow into the new streams, rolling back the chart strands the migrated topology and `0.4.x` pods will not recreate the old layout. Treat issues as fix-forward — the publisher gate means a stalled migration withholds readiness rather than corrupting data, so the fix is almost always completing the subscriber rollout. If you are stuck, capture the publisher and subscriber logs plus `nats stream report` output and [open an issue](../../../issues/new/choose).
