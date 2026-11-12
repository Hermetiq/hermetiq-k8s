# bb_clientd with Hermetiq Buildbarn

[bb_clientd](https://github.com/buildbarn/bb-clientd) is Buildbarn's client
daemon. It runs on a developer's machine, between the build client and the
Buildbarn frontend at `bb.<your-domain>`, and provides:

- a local caching proxy for the Remote Execution API, so repeat downloads come
  from local disk, across `bazel clean`, output bases and checkouts;
- a FUSE (Linux) or NFSv4 (macOS) mount at `~/bb_clientd`, whose `cas/`
  directory exposes CAS blobs as files that load when first read;
- the Bazel output service (Bazel 7.2 and later), which puts `bazel-out/` on
  that mount as lazy-loading files, so outputs are fetched only when something
  reads them.

It is optional. The chart needs no changes; bb_clientd is configured on each
workstation. It works well with Bazel. With Siso (Chromium) it helps only when
outputs repeat; see [Siso](#siso).

## Install

On Linux, install the Debian package from the
[latest release](https://github.com/buildbarn/bb-clientd/releases/latest) and run
it as a systemd user service:

```bash
curl -LO https://github.com/buildbarn/bb-clientd/releases/latest/download/bb_clientd.deb
sudo apt install ./bb_clientd.deb
systemctl --user enable --now bb_clientd
```

The package adds `user_allow_other` to `/etc/fuse.conf` and reads
`~/.config/bb_clientd/bb_clientd.jsonnet` when it exists. Logs go to
`~/.cache/bb_clientd/log`. Restart the service after changing the
configuration, then check that the mount is up:

```bash
systemctl --user restart bb_clientd
ls ~/bb_clientd   # cas  outputs  scratch
```

The release also has standalone binaries for Linux and macOS. To run one, copy
[`configs/bb_clientd.jsonnet`](https://github.com/buildbarn/bb-clientd/blob/main/configs/bb_clientd.jsonnet)
next to your configuration as `bb_clientd_defaults.jsonnet`, create the
directories listed in the bb-clientd README, and start it:

```bash
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"
OS="$(uname)" bb_clientd ~/.config/bb_clientd/bb_clientd.jsonnet
```

If
`/etc/fuse.conf` lacks `user_allow_other`, set
`mount+: { fuse+: { allowOther: false } }`.

## Configure

Create `~/.config/bb_clientd/bb_clientd.jsonnet`. It imports the defaults and
overrides three things: the cluster, the credential header, and TLS.

```jsonnet
local defaults = import 'bb_clientd_defaults.jsonnet';
defaults {
  // Instance names starting with this key go to this host. bb_clientd strips
  // the prefix before forwarding.
  clusters:: { 'bb.<your-domain>': 'bb.<your-domain>' },

  // Send the TLS server name (SNI). Some gateways reset TLS connections without it.
  grpcClient:: function(hostname, authorizationHeader, proxyURL)
    super.grpcClient(hostname, authorizationHeader, proxyURL) + { tls: { serverName: hostname } },
}
```

### Credentials

By default bb_clientd forwards the `authorization` header that Bazel's
credential helper adds, and reuses it for lazy reads through the mount. This
fits the chart's JWT authentication (`frontend.jwks`), where the helper returns
`Authorization: Bearer <token>`.

Hermetiq Cloud's credential helper returns `x-hermetiq-m2m-access-token`
instead. Add this field to the configuration to forward that header:

```jsonnet
  global+: { grpcForwardAndReuseMetadata: ['x-hermetiq-m2m-access-token'] },
```

bb_clientd keeps the forwarded credentials until the token expires or
bb_clientd restarts. A lazy read after that can fail until the next Bazel
command sends a fresh token.

### TLS server name

The default `grpcClient` connects to `<host>:443` with `tls: {}` and does not
set a server name. On our test cluster the gateway reset those connections.
The `tls.serverName` override above fixes this and does no harm where the
gateway does not require SNI.

## Bazel

Put the settings in `user.bazelrc`, since the paths are per person, and import
it from the workspace `.bazelrc` with `try-import %workspace%/user.bazelrc`.
Replace `<home>` with your home directory; a `.bazelrc` does not expand `$HOME`.

```bazelrc
build:bb-clientd --remote_cache=unix://<home>/.cache/bb_clientd/grpc
build:bb-clientd --remote_executor=unix://<home>/.cache/bb_clientd/grpc
build:bb-clientd --remote_instance_name=bb.<your-domain>/<project-id>
build:bb-clientd --remote_bytestream_uri_prefix=bb.<your-domain>/<project-id>
build:bb-clientd --experimental_remote_output_service=unix://<home>/.cache/bb_clientd/grpc
build:bb-clientd --experimental_remote_output_service_output_path_prefix=<home>/bb_clientd/outputs
build:bb-clientd --credential_helper=%workspace%/tools/bb-clientd-credential-helper
```

- `--remote_instance_name` starts with the cluster key from the configuration.
  bb_clientd routes on that prefix and strips it, so Buildbarn and Hermetiq see
  the project ID, as they do without bb_clientd.
- `--remote_bytestream_uri_prefix` makes `bytestream://` links in the build
  event stream point at `bb.<your-domain>` instead of the local socket, so
  Hermetiq and other build event consumers can read those blobs.
- Drop `--remote_executor` to use bb_clientd for caching only.
- Keep the BEP settings (`--bes_backend` and its scoped
  `--credential_helper=bep.<your-domain>=...`) as they are. BEP does not go
  through bb_clientd.

Bazel chooses a credential helper by host, and a socket has none, so the cache
helper has to be unscoped. An unscoped helper also answers for every other host
Bazel contacts, such as repository downloads. This wrapper answers only for
bb_clientd's socket and calls your project's helper:

```bash
#!/usr/bin/env bash
# Bazel sends the address it needs credentials for as JSON on stdin.
# Answer only for bb_clientd's socket; every other host gets none.
case "$(cat)" in
  *'"unix:'*) exec "$(dirname "$0")/hermetiq-credential-helper" "$@" </dev/null ;;
  *) echo '{}' ;;
esac
```

Save it as `tools/bb-clientd-credential-helper`, make it executable, and keep
both helpers out of version control. Build with `--config=bb-clientd`.

## Siso

Siso (Chromium) can use bb_clientd's caching proxy, but not the output service.
It connects to the socket only with `-reapi_insecure`, and in that mode it sends
no credentials. bb_clientd then has to attach a static token itself. Add this
field to the configuration:

```jsonnet
  // The file holds 'Bearer <token>'. Restart bb_clientd when it changes.
  authorizationHeader:: importstr '<home>/.cache/bb_clientd/authorization',
```

With `authorizationHeader` set, bb_clientd stops forwarding client
credentials, so use a separate configuration from the Bazel one. Write the file
from a credential helper that returns `Authorization`, and repeat before the
token expires (Auth0 tokens on our test cluster lasted 24 hours):

```bash
umask 077
helper get <<<'{"uri":"https://bb.<your-domain>"}' \
  | jq -j '.headers | to_entries[0].value[0]' > ~/.cache/bb_clientd/authorization
systemctl --user restart bb_clientd
```

Point Siso at the socket:

```bash
autoninja -C out/Default \
  -reapi_address=unix://$HOME/.cache/bb_clientd/grpc \
  -reapi_instance=bb.<your-domain>/<project-id> \
  -reapi_insecure \
  chrome
```

bb_clientd forwards Siso's request metadata, including `tool_invocation_id`,
so Hermetiq still links remote actions to the build.

### Measured results

Chromium `chrome` target with full output download (`-output_local_strategy=full`),
a warm cluster cache, and a workstation on Wi-Fi, measured on 2026-11-12:

| Case | Direct | Through bb_clientd |
|---|---|---|
| Outputs already in bb_clientd's local cache | 776 s, 10.2 GB downloaded | 410 s, 84 MB downloaded |
| Empty local cache | 776 s | 1,795 s, with 1,262 needless re-executions and about 10,000 retries |
| One-file rebuild | 204 s | 334 s |

bb_clientd sends all traffic to a cluster over one HTTP/2 connection, where
Siso alone opens 25. Under Siso's load the gateway reset that connection with
`GOAWAY` (`INTERNAL_ERROR`), failing the requests in flight on it. Raising bb_clientd's
CAS forwarding limit (`maximumConcurrency`) from 100 to 800 made reads fail with
`EOF`.

Use bb_clientd with Siso only where the same outputs are downloaded
repeatedly, for example several output directories of one checkout or builds
of the same revision. For incremental work, connect Siso to `bb.<your-domain>`
directly. Bazel was not timed.
