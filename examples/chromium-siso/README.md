# Chromium on Buildbarn with Hermetiq

- repository: https://chromium.googlesource.com/chromium/src
- latest tested revision: bbc7a3c29870e0a8b3a3ac31ae909a38ab3d6328 (159.0.8128.0)
- build tool: Siso v1.6.7

This tutorial builds Chromium on your own Buildbarn, shows each build in Hermetiq, and then makes it faster.

![Siso on the developer machine sends work to the Buildbarn frontend, which uses storage and the scheduler; the scheduler feeds a small and a large worker pool; siso-bep and the workers report to Hermetiq](images/architecture.svg)

## What you need

- Buildbarn and Hermetiq installed from this repository.
- Room for 40 worker nodes with 16 vCPUs and local SSD each. On GKE, the local SSD must back ephemeral storage (`--ephemeral-storage-local-ssd`).
- A Linux workstation with a Chromium checkout. Follow Chromium's [Linux build instructions](https://chromium.googlesource.com/chromium/src/+/HEAD/docs/linux/build_instructions.md) up to `fetch`.

The commands use the same placeholders as the [other examples](../envoy.md): `<your-domain>` is your installation's `hosts.domainBase`, `$INSTANCE_NAME` is your Hermetiq project ID, and `$CREDENTIAL_HELPER` is the path to your Hermetiq credential helper.

## 1. Set up the cluster

1. Merge [`buildbarn-values.yaml`](buildbarn-values.yaml) into your Buildbarn values and upgrade the release.
2. Add [`rbeworkers/`](rbeworkers/) as a component to the overlay you apply your RbeWorkers with, and apply it.
3. Check both pools are there:

   ```bash
   kubectl get rbeworkers -n <buildbarn-namespace> | grep chromium
   ```

There are two pools: a small one that stays up, and a large one that starts at zero. Buildbarn learns which actions need the large one.

## 2. Set up your workstation

1. Add the vars in [`client/gclient-custom-vars.txt`](client/gclient-custom-vars.txt) to your `.gclient`, then run `gclient runhooks`.
2. Copy [`client/args.gn`](client/args.gn) to `out/rbe/args.gn` and run `gn gen out/rbe`.
3. Check Siso can log in:

   ```bash
   export SISO_CREDENTIAL_HELPER=$CREDENTIAL_HELPER
   third_party/siso/cipd/siso auth-check -reapi_address=bb.<your-domain>:443 -reapi_instance=$INSTANCE_NAME
   ```

4. Install `siso-bep`, which reports Siso builds to Hermetiq:

   ```bash
   go install github.com/Hermetiq/hermetiq-k8s/tools/siso-bep@v0.1.0
   ```

## 3. Build Chromium

Run [`client/build.sh`](client/build.sh), or:

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

`siso-bep` prints a link to the build when it starts. [reference.md](reference.md#build-flags) explains the flags.

## 4. See it in Hermetiq

Open the link. You get the same view as a Bazel build: what ran remotely, the timeline and critical path, and which worker ran each action.

## 5. Make it faster, cheapest first

1. **Run every step remotely.** Free, and the biggest win. Without `default-remote` and `googlechrome`, thousands of steps run on your workstation. The command above already has both.
2. **Warm the pools before you build.** Costs some idle node time. The large pool takes several minutes to scale up from zero, and a cold build waits for it. Raise its `minReplicas`, or keep it warm during working hours with a KEDA cron window (see [reference.md](reference.md#the-pools)).
3. **Add nodes.** Costs money. We stopped at 40 because of our cloud quota.

To find your own bottleneck, open a slow build and click **Ask Barn Owl**. On one of ours, it found the pool ramp-up on its own and recommended warming the large pool.

## What we tried, in order

Each row is a cold build of `chrome`, with the remote cache off.

| Change | Build time |
| --- | --- |
| Siso's defaults, 16 nodes | 46 min |
| Up to 40 nodes, `--remote_jobs` 400 | 29 min |
| Add `default-remote` | 29 min |
| Keep links on the workstation (a local patch to Chromium's Siso config) | 23 min |
| Add `googlechrome` | 18 min |
| Double `--remote_jobs` to 800 | 17 min |
| Warm the pools first | 12 min |
| Shrink the small pool | slower |
| Drop the patch: Chromium's own config, pools starting cold | 21 min |
| Warm the pools first | 16 min |
| More actions per large pod | no faster |

The last three rows are what this example ships. The local patch was faster for us, but Chromium doesn't include it, so the example leaves it out.
