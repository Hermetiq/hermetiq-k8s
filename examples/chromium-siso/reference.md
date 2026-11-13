# Chromium example: reference

Details behind the [Chromium guide](README.md). For RbeWorker fields in general, see the [RbeWorker README](../../custom-values/rbeworkers/README.md).

## The pools

| | Small | Large |
| --- | --- | --- |
| Size class | 1 | 4 |
| Actions per pod (`spec.config.generated.concurrency`) | 24 | 9 |
| Pods (`spec.autoscaling.minReplicas`–`maxReplicas`) | 1–12 | 0–28 |
| Scale-up threshold (`spec.autoscaling.prometheus.threshold`) | 18 | 4 |
| Runner / worker | 13 CPU, 32 GiB / 2 CPU, 9 GiB | same |

- **Platform.** Both pools advertise `OSFamily=Linux` and the `siso-chromium` image, exactly as [`client/backend.star`](client/backend.star) requests. Buildbarn matches the whole property set, so a difference in either sends actions to a queue with no workers.
- **Size classes.** The scheduler runs an action it hasn't seen on the small class first, with a short timeout (`minimumExecutionTimeout` in [`buildbarn-values.yaml`](buildbarn-values.yaml)). An action that runs past it is retried on the large class, and the scheduler remembers where each action belongs (see [ISCC size classes](../../docs/iscc-size-classes.md)).
- **Actions per pod.** Large runs fewer, heavier actions. Raise `concurrency` on a pool when its slots are full but its CPU isn't, and add pods when work queues behind a pool whose CPU is busy. Barn Owl and the Hermetiq dashboard show both.
- **Thresholds** sit below `concurrency`, so a pool adds pods before the ones it has are full. A new node takes minutes to arrive.
- **Warm capacity.** Large scales to zero between builds to save money. A build that starts from zero waits for nodes: in this example's measurements the large pool took about 7 minutes to reach 28 pods. Raise `minReplicas` before a build when that matters, or keep a floor during working hours with a KEDA cron window (see the commented `cron` block in [`worker-ubuntu24-04.yaml`](../../custom-values/rbeworkers/worker-ubuntu24-04.yaml)).

## Build flags

| Flag | Why |
| --- | --- |
| `googlechrome` | Sends generator steps remote: mojo, Rust, nasm, TypeScript, grit and others. Without it they run on your workstation. |
| `default-remote` | Sends the remaining rules remote, including links. |
| `remote-link` | Links on a worker. `default-remote` already does this; it's listed to make the intent explicit. |
| `no-remote-timeout` | Removes Chromium's 2-minute remote timeout, which can expire while actions wait for a pool to scale up. |
| `--strict_remote` | Never runs a remote step on your workstation, even as a fallback. |
| `--remote_jobs=800` | Keeps work queued for every slot. Set it above your pools' total slots. |
| `-output_local_strategy=greedy` | Downloads final outputs, such as the `chrome` binary, but not intermediate object files. |

To measure a cold build, add `-re_cache_enable_read=false` and use a new output directory, so every step runs.

## Blob size limits

Buildbarn's block-based stores can't hold a blob bigger than one block, and an output bigger than that fails the build. Block size is `blocksSizeGi / (oldBlocks + currentBlocks + newBlocks + spareBlocks)`. The chart's default CAS has blocks of about 21 GiB, but check any store you've made smaller, and `frontend.readCache` if you enable it. Chromium's largest outputs:

| Output | Size |
| --- | --- |
| `chrome` | 715 MB |
| `v8_context_snapshot_generator` | 440 MB |
| `code_cache_generator` | 373 MB |

If you give `frontend.readCache` an `emptyDir` with a `sizeLimit`, set `frontend.resources.requests.ephemeral-storage` to match, or the kubelet can evict the frontend (see the chart README's Frontend Read Cache section).

## How a Siso build reaches Hermetiq

- **The build is created first.** `siso-bep` starts the invocation in Hermetiq before Siso runs, so records that arrive during the build have somewhere to go.
- **One ID ties it together.** `siso-bep` passes its invocation ID to Siso as `--build_id`, and Siso sends it to Buildbarn with every remote action as the REAPI `tool_invocation_id`.
- **Siso's record.** When Siso finishes, `siso-bep` reads its per-step metrics and sends one target per GN target, the remote, local and cache-hit counts, the critical path, and a trace profile (uploaded to Buildbarn's CAS) that gives Hermetiq the per-action timeline.
- **The workers' record.** Each worker reports every action it runs to Hermetiq's completed-action logger, with the pod that ran it and how long it queued and executed. Hermetiq files it under the same invocation by `tool_invocation_id`.

## Troubleshooting

| Symptom | Likely cause | Check |
| --- | --- | --- |
| `DeadlineExceeded` on a compile that waited in the queue | Chromium's 2-minute remote timeout | Add `no-remote-timeout` to `--config` |
| `Blob is N bytes in size, while this backend is only capable of storing blobs of up to M bytes` | An output larger than one block of a store | See [Blob size limits](#blob-size-limits) |
| `No workers exist for instance name prefix ...` | The client's platform doesn't match the pools', or the queue isn't predeclared while large is at zero | Compare `backend.star` with `platformProperties` and `predeclaredPlatformQueues` |
| Pods stay `Pending` | The node pool's maximum or a cloud quota | `kubectl -n kube-system get cm cluster-autoscaler-status -o yaml` names the limit, for example `QUOTA_EXCEEDED` |
| The build doesn't appear in Hermetiq | No `siso-bep`, or a wrong `--bes_backend` / `--project` | With `--results_url`, `siso-bep` prints a link to the build when it starts |
| Remote actions are missing from a build in Hermetiq | `-reapi_instance` differs from `--project`, or `completedActionLoggerAddress` is unset | Use the project ID for both |
| Workers mostly idle during a slow build | Work is running on your workstation | Check `googlechrome` and `default-remote` are in `--config`; Siso's `out/rbe/siso_metrics.json` shows which steps ran locally |

## Security

The worker container runs privileged for its FUSE build directory, as in every pool in this repository. See the [RbeWorker security notes](../../custom-values/rbeworkers/README.md#pod-security). The runner, which executes build actions, runs as a non-root user with no added capabilities.
