# Dex starter for the Hermetiq namespace

These starter files install Dex chart 0.25.2 in the `hermetiq` namespace. The
default public issuer is `https://dex.helm.hermetiq.dev`, matching the
`hosts.domainBase` example in `hermetiq-values.yaml`. Dex attaches an HTTPRoute
to the existing `hermetiq-gateway` in the same namespace. Prepare the Gateway,
DNS, and a TLS certificate covering the Dex hostname before running the script.
For another routing provider, edit `dex-values.yaml` using the
[Dex chart values](https://github.com/dexidp/helm-charts/tree/master/charts/dex).

After [copying `custom-values/`](../README.md#prepare-custom-values), run from
inside your copied values directory:

```bash
chmod +x dex-bootstrap.sh
DEX_DOMAIN_BASE=your-domain.example ./dex-bootstrap.sh
curl -fsS https://dex.your-domain.example/.well-known/openid-configuration
```

Use the same domain as `hosts.domainBase` in `hermetiq-values.yaml`. If your
Gateway has another name, set `DEX_GATEWAY_NAME`; set `KUBE_CONTEXT` to select a
non-current Kubernetes context. With no overrides, the script uses
`helm.hermetiq.dev`, `hermetiq-gateway`, and the current context. It adds the
official Dex Helm repository, pins chart version 0.25.2, and waits for Dex.
The sample HTTPRoute does not choose a specific listener, so the Gateway must
allow the route on its HTTPS listener.

## Dex login username and password

There is no default username in `dex-values.yaml`. On the first run,
`dex-bootstrap.sh` prompts for an email address; **that email is the Dex login
username**. In unattended mode, `DEX_ADMIN_EMAIL` supplies the username and
the script generates a password. For example, this creates the login
`admin@your-domain.example`:

```bash
DEX_DOMAIN_BASE=your-domain.example DEX_NONINTERACTIVE=1 \
  DEX_ADMIN_EMAIL=admin@your-domain.example ./dex-bootstrap.sh
cat ~/.config/hermetiq/dex/your-domain.example/dex-admin-password
```

If you use the interactive prompt, the password is the one you enter there.
The unattended password file has mode `0600`. The script writes the email as
both `staticPasswords[].email` and `staticPasswords[].username` in the
`hermetiq/dex-config` Secret, hashes the password with bcrypt, and creates
`hermetiq/dex-client` and `hermetiq/oauth2-proxy-client` Secrets. Use that
username and password when the dashboard redirects you to Dex. Run the script
before the manual
`oauth2-proxy-client` Secret step in the main installation guide; the script
creates that Secret for you. It reuses a complete set of existing Secrets and
stops on a partial set or an issuer mismatch. No password or client secret is
stored in Helm values or this repository. The local user gets the
`hermetiq-admin` group. Dex's Kubernetes storage retains signing keys and
sessions across Pod restarts; the chart installs the needed RBAC.

Set the following in your copied `hermetiq-values.yaml` before installing the
Hermetiq chart (replace the domain with yours):

```yaml
oidc:
  issuerUrl: https://dex.your-domain.example
  jwksUrl: https://dex.your-domain.example/keys
api:
  jwt:
    audience: "hermetiq-web"
    groupsClaim: groups
publisher:
  jwks:
    audience: "bazel-cli"
    groupsClaim: groups
dashboard:
  oauth2Proxy:
    scope: openid email profile groups offline_access
    backendLogoutUrl: # <-- remove this entry
```

The `hermetiq-web` client accepts the dashboard, Buildbarn Browser, and Grafana
`/oauth2/callback` URLs under your domain. Its ID tokens have audience
`hermetiq-web`; the Hermetiq API uses that audience from the shared OAuth
Secret.

Set the following in your copied `buildbarn-values.yaml` before installing the
buildbarn chart (replace the domain with yours):

```yaml
frontend:
  jwks:
    issuer: https://dex.your-domain.example
    audience: bazel-cli
    sync:
      url: https://dex.your-domain.example/keys
```

## Bazel on headless build machines

A separate public `bazel-cli` client is registered for interactive CLI
sign-in. For Bazel on a headless build machine, use [Dex's device authorization
flow](https://dexidp.io/docs/configuration/oauth2/). The helper runs on that
machine, displays a URL and code, and the user
approves the login in a browser elsewhere. The helper can then refresh tokens
locally without copying a refresh-token file between machines. This starter
does not supply machine credentials or a generic Bazel credential helper.
Configure the publisher and Buildbarn JWKS audiences to
match the tokens your Bazel clients will actually send before testing BEP or
remote execution. This local-user example has no MFA or account recovery.

To add users or rotate the password, update the `hermetiq/dex-config` Secret
and restart Dex. See [Dex configuration](https://dexidp.io/docs/configuration/),
[local users](https://dexidp.io/docs/connectors/local/), and
[public clients](https://dexidp.io/docs/configuration/custom-scopes-claims-clients/).
