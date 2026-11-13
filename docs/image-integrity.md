# Chart and image integrity

Hermetiq publishes separate public keys for Helm charts and container images:

| Artifact | Verification key | Signing key |
|---|---|---|
| OCI Helm charts | [`cosign.pub`](../cosign.pub) | Existing chart signing key |
| Container images | [`image-signing.pub`](../image-signing.pub) | Cloud KMS `hermetiq-artifact-signing/container-images`, version 1 |

Obtain these keys from a trusted copy of this repository. Pin the repository
commit when distributing key download URLs, and confirm the fingerprint through
a trusted channel. A key supplied alongside an untrusted artifact does not
independently establish the publisher's identity.

The publishers use Cosign 2.4.3. The examples below use Cosign 2.x to verify the
registry-stored signatures.

## Helm charts

Resolve the OCI chart's digest, then verify that digest before installing:

```sh
cosign verify --key cosign.pub \
  ghcr.io/hermetiq/hermetiq@sha256:<chart-digest>
```

Use `buildbarn` or `bb-worker-operator` in place of `hermetiq` for those charts.
This verifies the OCI artifact; it is separate from OpenPGP-based `helm verify`.
Check each historical chart version rather than assuming all versions were signed.

This public key verified the published `hermetiq` chart version `0.9.6`:

```sh
cosign verify --key cosign.pub \
  ghcr.io/hermetiq/hermetiq@sha256:b755aa1ceef50c843a5e8ca257f85abb6f35509ae6f9de09d38bccdb700fc68b
```

## Container images

The image signing private key remains in Google Cloud KMS. Customers need only
the public key; verification does not require Google Cloud credentials:

```sh
cosign verify --key image-signing.pub \
  us-docker.pkg.dev/hermetiq-cloud/hermetiq-public/<image>@sha256:<image-digest>
```

The release signing implementation covers `bep-nats`, `grpc-auth-proxy`,
`grpc-cache-proxy`, `prompt-runtime`, `hermetiq-web-ui`, and
`bb-worker-operator`. Key publication does not retroactively sign historical
versions. Verify the exact digest you deploy. Third-party mirrors and other
images in the public registry are not covered by that release implementation.

Image and chart signatures are separate: a signed chart does not sign the
container images it references. When mirroring, preserve the image digest and
copy its Cosign signature artifacts too; verify again at the destination.

## Pin image digests

A tag such as `v0.9.6` is resolved when a node pulls the image, so a tag-only
reference runs whatever the registry serves under that tag at that moment. A
digest names fixed content. When a digest is set, the charts render
`repository:tag@sha256:<digest>`; the runtime pulls by digest and the tag is
only a label.

The Hermetiq-built images and their digest fields are:

| Chart | Image | Digest field |
|---|---|---|
| `hermetiq` | `bep-nats` | `images.bepNats.apiDigest`, `pubDigest`, `subDigest`, `bootstrapDigest` |
| `hermetiq` | `grpc-auth-proxy` | `images.authProxy.digest` |
| `hermetiq` | `hermetiq-web-ui` | `images.dashboard.digest` |
| `hermetiq` | `prompt-runtime` | `images.promptRuntime.digest` |
| `hermetiq` | `oauth2-proxy` (mirror) | `images.oauth2Proxy.digest` |
| `buildbarn` | `grpc-cache-proxy` | `images.grpcCacheProxy.digest` |
| `bb-worker-operator` | `bb-worker-operator` | `image.digest` |

### Installing

Pin each image you deploy in your values file, using a digest you verified with
`cosign verify` as shown above:

```yaml
images:
  authProxy:
    tag: "v0.9.6"
    digest: "sha256:<image-digest>"
```

Change the tag and the digest together. Once a digest is set, the runtime
pulls that digest whatever the tag says, so a new tag alone does not change the
image. Setting a digest to `""` returns that image to pulling by tag.

### Releasing a chart

The publish step (`.buildkite/scripts/publish-chart.sh`) runs
`.buildkite/scripts/image-digest-check.sh` on release tags. It fails the release
if any default image in `us-docker.pkg.dev/hermetiq-cloud/hermetiq-public`
lacks a `sha256:` digest in the chart's `values.yaml`. Chart PRs are not gated,
because images change while a release is being prepared. Before tagging, the
release PR sets each digest in the table above to the digest of the signed
release image. Look up the digest, then confirm its signature:

```sh
gcloud artifacts docker images describe \
  us-docker.pkg.dev/hermetiq-cloud/hermetiq-public/<image>:<tag> \
  --format='value(image_summary.digest)'
cosign verify --key image-signing.pub \
  us-docker.pkg.dev/hermetiq-cloud/hermetiq-public/<image>@sha256:<image-digest>
```

Third-party images that the charts pull from their upstream registries, such
as `ghcr.io/buildbarn/*`, are not gated. Pin their digests in your values in
the same way.

## Public-key fingerprints

Fingerprints are SHA-256 of the DER-encoded SubjectPublicKeyInfo, calculated with:

```sh
openssl pkey -pubin -in cosign.pub -outform DER | openssl dgst -sha256
openssl pkey -pubin -in image-signing.pub -outform DER | openssl dgst -sha256
```

The chart public-key fingerprint is
`037f810ecb56e308095f694eb1c3d1cd0cd2b6269186a3c3c28ebe453061cb78`.

The image public-key fingerprint is
`572a26fff45c3d731b2ed0cd1d91f010bad8ad8faee0561a7784a2dc780f64d4`.

Key rotation must publish a new verification key and identify the releases it
signs. Keep old public keys available for verification of historical artifacts.
