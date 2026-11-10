# Chromium on Buildbarn with Hermetiq

- repository: https://chromium.googlesource.com/chromium/src
- latest tested revision: bbc7a3c29870e0a8b3a3ac31ae909a38ab3d6328 (159.0.8128.0)
- build tool: Siso v1.6.7

Chromium's `chrome` target is about 57,800 build steps, most of them C++ compiles, with link outputs of up to 715 MB. This example builds it remotely on a Buildbarn installed from this repository, shows each build in Hermetiq, and uses Barn Owl to find what's slowing it down. On 40 nodes, a cold build takes 16 minutes with the worker pools warm, down from 21 when they start from zero.

## Contents

1. [How the parts fit](#1-how-the-parts-fit)
2. [Set up the client](#2-set-up-the-client)
3. [Set up the cluster](#3-set-up-the-cluster)
4. [Build Chromium](#4-build-chromium)
5. [See the build in Hermetiq](#5-see-the-build-in-hermetiq)
6. [Find what's slowing it down with Barn Owl](#6-find-whats-slowing-it-down-with-barn-owl)

Field-by-field pool details, autoscaling and troubleshooting are in [reference.md](reference.md).

## 1. How the parts fit

![Siso on the developer machine talks to the Buildbarn frontend, which uses storage and the scheduler; the scheduler feeds a small and a large worker pool; siso-bep and the workers report to Hermetiq](images/architecture.svg)

| Part | What it does |
| --- | --- |
| Siso | Chromium's build tool. Decides which steps run remotely and sends them to Buildbarn. |
| [`siso-bep`](../../tools/siso-bep/) | Runs Siso and reports the build to Hermetiq as Build Event Protocol events, the way Bazel does on its own. |
| Buildbarn frontend | Checks credentials and passes blobs to storage and actions to the scheduler. |
| Buildbarn scheduler | Queues actions by platform and learns which ones need the large pool. |
| Two worker pools | Size class 1 (24 actions per pod) and size class 4 (9 actions per pod), one pod per 16-vCPU node. |
| Hermetiq | Build history, targets, remote actions, the timeline and critical path for every build, and Barn Owl. |

## 2. Set up the client

You need a Linux workstation with [depot_tools](https://chromium.googlesource.com/chromium/tools/depot_tools.git) and a Chromium checkout. Follow Chromium's [Linux build instructions](https://chromium.googlesource.com/chromium/src/+/HEAD/docs/linux/build_instructions.md) up to `fetch`, then point Siso at your Buildbarn with Chromium's [non-Google RBE settings](https://chromium.googlesource.com/chromium/src/+/HEAD/docs/linux/build_instructions.md#non-google-rbe):

1. Add the custom vars in [`client/gclient-custom-vars.txt`](client/gclient-custom-vars.txt) to your `.gclient`, pointing `reapi_backend_config_path` at [`client/backend.star`](client/backend.star). The backend config gives every remote action Chromium's public `siso-chromium` runner image as its platform.
2. Run `gclient runhooks`.
3. Create the output directory: copy [`client/args.gn`](client/args.gn) to `out/rbe/args.gn`, then run `gn gen out/rbe`.
4. Point Siso at your Hermetiq credential helper and check that it can authenticate:

   ```bash
   export SISO_CREDENTIAL_HELPER=$CREDENTIAL_HELPER
   third_party/siso/cipd/siso auth-check -reapi_address=bb.<your-domain>:443 -reapi_instance=$INSTANCE_NAME
   ```

5. Install `siso-bep`:

   ```bash
   go install github.com/Hermetiq/hermetiq-k8s/tools/siso-bep@v0.1.0
   ```

`<your-domain>` is your installation's `hosts.domainBase`, `$INSTANCE_NAME` is your Hermetiq project ID, and `$CREDENTIAL_HELPER` is the path to your Hermetiq credential helper, as in the [other examples](../envoy.md).

## 3. Set up the cluster

1. **Buildbarn values.** Merge [`buildbarn-values.yaml`](buildbarn-values.yaml) into your Buildbarn values and upgrade the release:
   - size-class analysis, which needs the ISCC store (see [ISCC size classes](../../docs/iscc-size-classes.md))
   - the File System Access Cache, which the pools' input prefetching needs
   - the predeclared queue for the Chromium platform

   Chromium's `chrome` binary is 715 MB, and Buildbarn can't store a blob bigger than one block of a store. Check your blocks are bigger than that; see [reference.md](reference.md#blob-size-limits).
2. **Nodes.** The pools expect 16-vCPU nodes with local SSD, one worker pod per node: a 13-CPU runner and a 2-CPU worker. The workers keep their cache and build files in `emptyDir` volumes, so the local SSD must back the node's ephemeral storage (on GKE, `--ephemeral-storage-local-ssd`). Set the node pool's maximum, and your cloud's quota (including local SSD quota), to at least the pools' combined maximum of 40.
3. **Pools.** Add [`rbeworkers/`](rbeworkers/) as a component to the overlay you apply your RbeWorkers with, then apply it:

   ```bash
   kubectl get rbeworkers,scaledobjects -n <buildbarn-namespace> | grep chromium
   ```

   Both pools should be listed. Small keeps one pod running; large starts at zero and scales on demand.

## 4. Build Chromium

The everyday command is [`client/build.sh`](client/build.sh). It sends every step to Buildbarn, including links, reads from the remote cache, and downloads only the outputs you need locally:

```bash
siso-bep --bes_backend=grpcs://bep.<your-domain> --project=$INSTANCE_NAME \
  --results_url=https://dashboard.<your-domain>/build/ -- \
  autoninja -C out/rbe \
    -reapi_address=bb.<your-domain>:443 -reapi_instance=$INSTANCE_NAME \
    --strict_remote --remote_jobs=800 \
    --config=no-remote-timeout,default-remote,googlechrome,remote-link \
    -output_local_strategy=greedy \
    chrome
```

| Setting | Why |
| --- | --- |
| `googlechrome` | Sends generator steps remote: mojo, Rust, nasm, TypeScript, grit and others. Without it they run on your workstation and become the bottleneck. |
| `default-remote` | Sends the remaining rules remote, including links. |
| `remote-link` | Links on a worker. `default-remote` already does this; it's listed to make the intent explicit. |
| `no-remote-timeout` | Removes Chromium's 2-minute remote timeout, which can expire while actions wait for a pool to scale up. |
| `--strict_remote` | Never runs a remote step on your workstation, even as a fallback. |
| `--remote_jobs=800` | Keeps actions queued behind every slot. Set it above your total slots, which is 540 for these pools. |
| `-output_local_strategy=greedy` | Downloads final outputs, such as the `chrome` binary, but not intermediate object files. |

## 5. See the build in Hermetiq

`siso-bep` gives each Siso build the same record a Bazel build gets. Open it in Build History to see what ran remotely, the timeline and critical path, and which workers ran each action. [reference.md](reference.md#how-a-siso-build-reaches-hermetiq) explains how the pieces are tied together.

## 6. Find what's slowing it down with Barn Owl

Open a slow build in Build History, click **Ask Barn Owl**, and ask where the time went. For a cold build that took 20m 55s, we asked:

> Where did its time go, what limited it, and what should I change in the worker pools to make it faster?

Barn Owl read the build, the scheduler's queues and the pools' scaling history, and answered:

> The build was execution-bound on a cold, shared remote fleet, and its single largest recoverable loss was the ~7-minute worker ramp-up at the start: the large Siso pool was at zero replicas when the build began and did not reach its 28-replica cap until ~17:22, roughly 7 minutes into a 20m55s build. Steady-state execution after that looked healthy.

It also checked what wasn't limiting the build: inputs and outputs moved quickly, and the queue drained once the pool was full, so more pods wouldn't help. Its recommendation:

> Raising the large pool's `minReplicas` above 0 (or pre-warming it before a known cold build) is the change most directly supported by this evidence, since the ramp-up gap is measured.

With both pools warm, the same build takes 16m 17s. Set `minReplicas` in [`rbeworkers/worker-chromium-large.yaml`](rbeworkers/worker-chromium-large.yaml), or keep the pool warm only during working hours with a KEDA cron window (see [reference.md](reference.md#the-pools)). Warm pools cost node time while they sit idle.

Most of the remaining time is at the end of the build. The critical path finishes with the `chrome` link, and 2–4 minutes of that goes to downloading the 715 MB binary to the workstation.

You can ask the same questions from your own coding agent through Hermetiq's MCP server.

## How it was measured

On 10 November 2026, at the Chromium revision above, from an 8-core Linux workstation, on 40 spot 16-vCPU nodes with local SSD (28 large, 12 small). Each build used a new output directory with remote cache reads off (`-re_cache_enable_read=false`), so every step ran. Three builds per setup:

- Pools starting from zero: 20m 55s, 21m 18s, 23m 12s.
- Pools warm: 15m 17s, 16m 17s, 16m 28s.
- Pools warm with 12 actions per large pod instead of 9: 15m 37s, 17m 21s. The third build didn't finish.
