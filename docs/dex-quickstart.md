# Dex for a test installation

[Dex](https://dexidp.io/docs/) provides a small OIDC provider when an
organization identity provider is not ready. The copyable
[`custom-values/dex-*` starter](../custom-values/dex-README.md) installs Dex
in the `hermetiq` namespace with one local user. It creates the Dex Secrets
and the shared `oauth2-proxy-client` Secret used by the dashboard, Grafana,
and Buildbarn Browser.

First prepare DNS, TLS, and a Gateway that accepts an HTTPRoute for
`dex.<your-domain>`. [Copy the starter values](../README.md#prepare-custom-values),
then run from the copied values directory:

```bash
DEX_DOMAIN_BASE=your-domain.example ./dex-bootstrap.sh
```

The email entered at the bootstrap prompt is the Dex login username. For
unattended setup, set `DEX_ADMIN_EMAIL` to that username; the generated
password path is in the
[Dex starter instructions](../custom-values/dex-README.md#dex-login-username-and-password).

Use the same domain in `hermetiq-values.yaml`, and follow the
[Dex starter instructions](../custom-values/dex-README.md) for the issuer,
JWKS URL, groups claim, existing Secrets, and verification. The starter
registers a public `bazel-cli` client, but Bazel token acquisition and
machine credentials require separate configuration. For a headless Bazel
machine, use Dex's device authorization flow so the user can approve a code
from another browser and the refresh token stays on the Bazel machine. See
the [starter's Bazel note](../custom-values/dex-README.md#bazel-on-headless-build-machines)
for the scope of this example. It has no MFA or account recovery.
