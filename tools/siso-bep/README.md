# siso-bep

`siso-bep` runs a [Siso](https://chromium.googlesource.com/build/+/refs/heads/main/siso/) build, the build tool Chromium uses, and reports it to Hermetiq as Build Event Protocol (BEP) events. Bazel sends BEP on its own; Siso doesn't. With `siso-bep`, a Siso build shows up in Hermetiq like a Bazel build: build history, targets, remote-execution and cache counts, a timeline with the critical path, and Barn Owl.

```text
siso-bep
 ├─ 1. Before the build:  connect to Hermetiq and send "invocation started"
 ├─ 2. Start Siso:        add --build_id, --job_id and --frontend_file to its command line
 ├─ 3. While it runs:     stream console output, track steps from the frontend pipe
 ├─ 4. After it exits:    read Siso's files, send targets, metrics, profile, result
 └─ 5. Finish:            send "invocation finished", exit with Siso's own exit code
```

## Install

```bash
go install github.com/Hermetiq/hermetiq-k8s/tools/siso-bep@latest
```

Pin a release in scripts and CI, for example `@tools/siso-bep/v0.1.0`. It needs Go 1.26 or later to build. The binary is pure Go and has no runtime dependencies.

## Use

Put `siso-bep` and its flags in front of the build command, then `--`:

```bash
export SISO_CREDENTIAL_HELPER=/path/to/credential-helper

siso-bep --bes_backend=grpcs://<your Hermetiq BEP endpoint> --project=<project ID> -- \
  autoninja -C out/Default \
    -reapi_address=<your Buildbarn address>:443 -reapi_instance=<project ID> \
    chrome
```

The build runs exactly as it would without the wrapper, with the same terminal output and the same exit code. If Hermetiq can't be reached when the build starts, `siso-bep` logs it and runs the build without reporting.

| Flag | Meaning |
| --- | --- |
| `--bes_backend` | Hermetiq's BEP endpoint: `grpcs://host:port` (TLS) or `grpc://host:port` (plaintext). Empty runs the build without reporting. |
| `--project` | Hermetiq project ID. Siso's `-reapi_instance` must be the same ID so remote actions reported by the Buildbarn workers attach to the build. |
| `--credential_helper` | Bazel-style credential helper for Hermetiq and the profile upload. Defaults to `$SISO_CREDENTIAL_HELPER`, the one Siso uses. |
| `--metadata KEY=VALUE` | Build metadata, like Bazel's `--build_metadata`. Repeatable. Use it for tags or a branch name on a detached checkout. |
| `--bes_header NAME=VALUE` | Extra request header. Repeatable. |
| `--all_actions` | Report every step as an action, not only failed ones. Hermetiq keeps successful actions only for projects that enable it. |
| `--no_profile` | Skip the trace profile upload. Hermetiq's timeline and critical path need it. |
| `--no_frontend` | Don't pass `-frontend_file` to Siso. Failed steps then show no output. |
| `--results_url` | Printed with the invocation ID appended, as a link to the build. |
| `--flush_timeout` | How long to wait for Hermetiq after the build finishes (default 60s). |
| `--user` | Sent as `x-forwarded-user`, for endpoints that trust a forwarded identity. |

## What it reports

- **Invocation started**, before Siso runs, so the build exists in Hermetiq before the first remote action arrives. The invocation ID is passed to Siso as `--build_id`, which Siso sends to Buildbarn as the REAPI `tool_invocation_id`. That is how remote actions reported by the workers and the events below land on the same build.
- **While the build runs:** console output as Progress events, and step results from Siso's `-frontend_file` stream.
- **After the build**, from the files Siso writes to the output directory:
  - `siso_metadata.json`: Siso version, targets and flags.
  - `siso_metrics.json`: one record per step. Becomes a target per GN target, BuildMetrics (remote, local and cache-hit counts), a critical path, and a Bazel-format trace profile uploaded to Buildbarn's CAS.
  - `siso_output`: failed steps' output, when the frontend stream had none.
- **Finished**, with the build's result and exit code.

## Develop

```bash
go vet ./...
go test ./...
```

`pb/` holds Go code generated from Bazel's BEP protos in `proto/` (Apache 2.0, © The Bazel Authors). Regenerate it with `buf generate` from this directory.

This copy is taken from Hermetiq's main repository at commit `35539b5f`.
