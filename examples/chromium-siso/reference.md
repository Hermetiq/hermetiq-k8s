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

## The frontend read cache

`frontend.readCache` caches recently read blobs on each frontend replica. A blob can't span blocks, so any output bigger than one block fails the build instead of just missing the cache. Block size is `blocksSizeGi / (oldBlocks + currentBlocks + newBlocks + spareBlocks)`. Chromium's largest outputs:

| Output | Size |
| --- | --- |
| `chrome` | 715 MB |
| `v8_context_snapshot_generator` | 440 MB |
| `code_cache_generator` | 373 MB |

8 GiB over 10 blocks gives 819 MiB blocks. Scale `keyLocationMapInMemoryEntries` and the volume's `sizeLimit` with `blocksSizeGi`, as the chart's values comments describe.

## Troubleshooting

| Symptom | Likely cause | Check |
| --- | --- | --- |
| `DeadlineExceeded` on a compile that waited in the queue | Chromium's 2-minute remote timeout | Add `no-remote-timeout` to `--config` |
| `Blob is N bytes in size, while this backend is only capable of storing blobs of up to M bytes` | An output larger than one frontend read-cache block | Raise `frontend.readCache.blocksSizeGi` |
| `No workers exist for instance name prefix ...` | The client's platform doesn't match the pools', or the queue isn't predeclared while large is at zero | Compare `backend.star` with `platformProperties` and `predeclaredPlatformQueues` |
| Pods stay `Pending` | The node pool's maximum or a cloud quota | `kubectl -n kube-system get cm cluster-autoscaler-status -o yaml` names the limit, for example `QUOTA_EXCEEDED` |
| The build doesn't appear in Hermetiq | No `siso-bep`, or a wrong `--bes_backend` / `--project` | `siso-bep` prints the invocation ID when it starts |
| Remote actions are missing from a build in Hermetiq | `-reapi_instance` differs from `--project`, or `completedActionLoggerAddress` is unset | Use the project ID for both |
| Workers mostly idle during a slow build | Work is running on your workstation | Check `googlechrome` and `default-remote` are in `--config`; Siso's `out/rbe/siso_metrics.json` shows which steps ran locally |

## Security

The worker container runs privileged for its FUSE build directory, as in every pool in this repository. See the [RbeWorker security notes](../../custom-values/rbeworkers/README.md#pod-security). The runner, which executes build actions, runs as a non-root user with no added capabilities.
