# drake

- repository: https://github.com/RobotLocomotion/drake
- latest tested revision: c72e0affe (the commit pinned by
  [`examples/drake-runner-image`](drake-runner-image))

## Bazel Version

The project is configured to use Bazel version 9.2.0. If you are using
Bazelisk, then set `USE_BAZEL_VERSION=9.2.0`.

## Build Image

Building Drake remotely needs
[`examples/drake-runner-image`](drake-runner-image), a Buildbarn runner image
with Drake's commit-matched Ubuntu 24.04 developer prerequisites (CMake, GCC
13, GNU Fortran 13, Clang 20, LLD). Build and publish that image first, then
deploy a dedicated worker pool for it:

- [`custom-values/rbeworkers/optional/drake/worker-drake.yaml`](../custom-values/rbeworkers/optional/drake/worker-drake.yaml)

Apply that worker after the Buildbarn chart has rendered the shared
`buildbarn-worker-config` ConfigMap, then set its `images.runner` to your
published `<registry>/drake-runner@sha256:<digest>`.

### Remote execution platform

Drake uses `rules_cc` local toolchain autoconfiguration, which inspects the
compiler on the machine invoking Bazel, so install Clang 20 on the build
client as well as the runner. Select the runner image with a dedicated
platform rather than `--remote_default_exec_properties`: Buildbarn matches
worker platform properties exactly, so adding `Arch` or `OSFamily` alongside
`container-image` prevents the worker from matching. Add the following to the
Drake checkout:

```starlark
# rbe/BUILD.bazel
platform(
    name = "linux_x86_64",
    exec_properties = {
        "container-image": "docker://<registry>/drake-runner@sha256:<digest>",
    },
)
```

Select it on the command line or in `user.bazelrc`:

```text
--platforms=//rbe:linux_x86_64
--extra_execution_platforms=//rbe:linux_x86_64
```

## Project Configuration

Make public dependencies such as `fmt` Bazel module inputs instead of
requiring the runner image to mirror every system development package present
on the client:

```text
--@drake//tools/flags:public_repo_default=module
```

### Hermetiq Configuration

Configure the Hermetiq Build Event Protocol (BEP) backend, remote cache, and
remote execution for Bazel as follows.

Replace the following placeholders with your Hermetiq account data.

- `$INSTANCE_NAME`: Your Project ID.
- `$CREDENTIAL_HELPER`: Path to your credential helper executable.
- `<your-domain>`: The `hosts.domainBase` you configured for the Hermetiq
  and Buildbarn charts. These examples assume both charts share one base
  domain, giving `bep.<your-domain>` (BEP), `bb.<your-domain>` (Buildbarn
  frontend gRPC), and `dashboard.<your-domain>` (web UI).

A convenient approach is to add a `hermetiq` config to `user.bazelrc` in the
Drake checkout. Use `common:hermetiq` for the BEP settings so they also apply
to `bazel test` and other commands, not just `bazel build`:

```bazelrc
common:hermetiq --bes_instance_name=$INSTANCE_NAME
common:hermetiq --bes_backend=grpcs://bep.<your-domain>
common:hermetiq --bes_results_url=https://dashboard.<your-domain>/build/
common:hermetiq --bes_upload_mode=wait_for_upload_complete
common:hermetiq --bes_timeout=600s
common:hermetiq --credential_helper=bep.<your-domain>=$CREDENTIAL_HELPER

build:hermetiq --remote_instance_name=$INSTANCE_NAME
build:hermetiq --remote_cache=grpcs://bb.<your-domain>
build:hermetiq --remote_executor=grpcs://bb.<your-domain>
build:hermetiq --credential_helper=bb.<your-domain>=$CREDENTIAL_HELPER
build:hermetiq --platforms=//rbe:linux_x86_64
build:hermetiq --extra_execution_platforms=//rbe:linux_x86_64
build:hermetiq --remote_timeout=600s
build:hermetiq --remote_retries=5
build:hermetiq --remote_retry_max_delay=30s
build:hermetiq --remote_download_outputs=minimal
build:hermetiq --remote_local_fallback=false
```

The longer `--bes_timeout` and `--remote_timeout` (600s, versus 120s in the
smaller examples above) accommodate Drake's build size — tens of thousands of
actions in a full build.

### Build Targets

```bash
bazel build --config=hermetiq --config=clang //...
```

### Status

This configuration has not yet completed a full
`bazel build --config=clang //...`. The latest full-build attempt reached
56,514 of 63,895 reported actions (7,288 remote executions) before failing on
a GNU Fortran driver lookup (`f951`) that a newer `drake-runner-image`
revision addresses; that fix has not yet been confirmed by another full run.
Individual remote actions (compiles, links) succeed against the worker pool
above, which proves the endpoints, credentials, remote instance, and platform
selection are working end to end.
