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
