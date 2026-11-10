# chromium

- repository: https://chromium.googlesource.com/chromium/src
- latest tested revision: bbc7a3c29870e0a8b3a3ac31ae909a38ab3d6328 (159.0.8128.0)

## Siso Version

Chromium builds with Siso, not Bazel. This example was tested with Siso
v1.6.7, which depot_tools installs with the checkout. Follow Chromium's
[Linux build instructions](https://chromium.googlesource.com/chromium/src/+/HEAD/docs/linux/build_instructions.md)
up to `fetch` to get a checkout.

## Build Image

Chromium's remote actions run in Google's public `siso-chromium` image. This
example deploys two worker pools for it on the same platform: a small pool that
keeps one pod running, and a large pool for heavy actions that starts at zero.

The pools need 40 nodes at most, each with 16 vCPUs and local SSD. On GKE, the
local SSD must back the nodes' ephemeral storage
(`--ephemeral-storage-local-ssd`). Check your cloud quota, including local SSD.

Buildbarn needs four settings for the pools:

- `iscc`: a store where the scheduler records which pool each action needs.
- `fsac`: a store the workers use to prefetch each action's inputs.
- `sizeClassAnalysis`: sends a new action to the small pool first. If it runs
  longer than `minimumExecutionTimeout`, it moves to the large pool.
- `predeclaredPlatformQueues`: lets builds start while the large pool is at
  zero.

Add them to your Buildbarn values and upgrade the release. They're also in
[`buildbarn-values.yaml`](buildbarn-values.yaml). If you already have
`predeclaredPlatformQueues`, add this entry to your list, because Helm replaces
lists rather than merging them.

```yaml
storage:
  persistence:
    iscc:
      enabled: true
    fsac:
      enabled: true
scheduler:
  sizeClassAnalysis:
    enabled: true
    pageRank:
      minimumExecutionTimeout: 60s
  predeclaredPlatformQueues:
    - platform:
        - {name: OSFamily, value: Linux}
        - {name: container-image, value: "docker://gcr.io/chops-public-images-prod/rbe/siso-chromium/linux@sha256:d7cb1ab14a0f20aa669c23f22c15a9dead761dcac19f43985bf9dd5f41fbef3a"}
      sizeClasses: [1, 4]
```

Next, add the worker pools. [`rbeworkers/`](rbeworkers/) is a kustomize
component, so it goes into the overlay you already use to apply your
RbeWorkers. That way your overlay's namespace and settings apply to these pools
too. In the overlay's `kustomization.yaml`, add:

```yaml
components:
  - <path-to-hermetiq-k8s>/examples/chromium-siso/rbeworkers
```

`<path-to-hermetiq-k8s>` is this repository's checkout, relative to the overlay.
Add your node pool's label to the pools' `nodeSelector` the same way as for
your other pools, then apply the overlay and check the pools are there:

```bash
kubectl apply -k <your-overlay>
kubectl get rbeworkers -n hermetiq | grep chromium
```

## Project Configuration

Point the checkout at your Buildbarn by adding these custom vars to the `src`
solution in `.gclient`, then run `gclient runhooks`.
[`client/backend.star`](client/backend.star) gives every remote action the
same platform as the worker pools.

```python
"custom_vars": {
  "reapi_address": "bb.<your-domain>:443",
  "reapi_instance": "$INSTANCE_NAME",
  "reapi_backend_config_path": "/path/to/examples/chromium-siso/client/backend.star",
},
```

Create an output directory with [`client/args.gn`](client/args.gn), a release
build without symbols that uses remote execution:

```bash
mkdir -p out/rbe
cp /path/to/examples/chromium-siso/client/args.gn out/rbe/args.gn
gn gen out/rbe
```

### Hermetiq Configuration

Replace the following placeholders with your Hermetiq account data.

- `$INSTANCE_NAME`: Your Project ID.
- `$CREDENTIAL_HELPER`: Path to your credential helper executable.
- `<your-domain>`: The `hosts.domainBase` you configured for the Hermetiq
  and Buildbarn charts. These examples assume both charts share one base
  domain, giving `bep.<your-domain>` (BEP), `bb.<your-domain>` (Buildbarn
  frontend gRPC), and `dashboard.<your-domain>` (web UI).

Siso doesn't send Build Event Protocol events itself, so the build runs under
[`siso-bep`](../../tools/siso-bep/), which reports it to Hermetiq the way Bazel
does. Install it and check that Siso can authenticate:

```bash
go install github.com/Hermetiq/hermetiq-k8s/tools/siso-bep@v0.1.0
export SISO_CREDENTIAL_HELPER=$CREDENTIAL_HELPER
third_party/siso/cipd/siso auth-check -reapi_address=bb.<your-domain>:443 -reapi_instance=$INSTANCE_NAME
```

### Build Targets

The following command builds `chrome` with every step running remotely. The
same command is in [`client/build.sh`](client/build.sh), and
[`reference.md`](reference.md#build-flags) explains each flag.

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

`siso-bep` prints a link to the build in Hermetiq when it starts.

### Making It Faster

Try these in order. Each one costs more than the one before.

1. Send every step to Buildbarn. This costs nothing and helps the most.
   Chromium's default Siso config runs thousands of steps on your workstation,
   which then becomes the bottleneck. The `default-remote` and `googlechrome`
   options in the command above send those steps to the worker pools.
2. Start the large pool before you build. It scales down to zero between
   builds and takes several minutes to scale back up, so a build that starts
   while it's at zero waits for it. Set its `minReplicas` above zero, or keep
   it running during working hours with a KEDA cron window. You pay for the
   nodes while they sit idle.
3. Add nodes. More nodes cost more money. We stopped at 40 because of our
   cloud quota.

To see what's slowing down your own builds, open a slow build in Hermetiq and
click **Ask Barn Owl**. When we asked it about one of ours, it found that the
build was waiting for the large pool to scale up, and recommended keeping that
pool running.

What we tried, in order. Each row is a cold build of `chrome` with remote cache
reads off.

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

The last three rows are what this example ships. The local patch was faster for
us, but Chromium doesn't include it, so the example leaves it out.

### Troubleshooting

Common errors and their fixes are in
[`reference.md`](reference.md#troubleshooting), along with the pool settings
and Buildbarn's blob size limits.
