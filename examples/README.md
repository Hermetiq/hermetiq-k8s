# Examples

This directory contains runnable examples and project notes for validating
Hermetiq and Buildbarn remote execution setups. The examples range from small
smoke tests to larger open-source repositories that exercise C++, Go, Rust, and
container-dependent workflows.

## Table of Contents

- [Testcontainers](#testcontainers)
- [Sysbox Runner Image](#sysbox-runner-image)
- [Drake Runner Image](#drake-runner-image)
- [abseil-cpp](#abseil-cpp)
- [bazel-examples](#bazel-examples)
- [codex](#codex)
- [drake](#drake)
- [envoy](#envoy)

## Testcontainers

`testcontainers/` is the most complete example in this directory. It is a
self-contained Bazel + Go workspace that runs Testcontainers tests through
Buildbarn remote execution.

It includes:

- A lightweight Redis smoke test.
- A larger Vespa deploy/feed/query workflow.
- Per-target `exec_properties` that route Docker-dependent tests to the
  Buildbarn Testcontainers worker pool.
- GKE node pool requirements for both DinD and Sysbox worker fleets.

Start here when validating that Docker-capable Buildbarn workers are wired
end-to-end:

- [testcontainers/README.md](testcontainers/README.md)

## Sysbox Runner Image

`sysbox-runner-image/` contains an example Dockerfile and entrypoint for a
Buildbarn runner image that starts Docker inside the runner container under
Sysbox.

Use it with `custom-values/rbeworkers/optional/testcontainers-sysbox/worker-testcontainers-sysbox.yaml` when
you want a Sysbox-backed worker pool instead of the Docker-in-Docker sidecar
pool.

- [sysbox-runner-image/README.md](sysbox-runner-image/README.md)

## Drake Runner Image

`drake-runner-image/` contains an Ubuntu 24.04 x86-64 Buildbarn runner image
with CMake, GCC 13, and Clang 20 for building Drake remotely. Deploy it with
[`custom-values/rbeworkers/optional/drake/worker-drake.yaml`](../custom-values/rbeworkers/optional/drake/worker-drake.yaml).

- [drake-runner-image/README.md](drake-runner-image/README.md)

## abseil-cpp

`abseil-cpp.md` documents a tested Hermetiq configuration for
`github.com/abseil/abseil-cpp`, including the Bazel version, a hermetic C/C++
toolchain patch, project flags, BEP upload, remote cache, and remote execution
settings.

- [abseil-cpp.md](abseil-cpp.md)

## bazel-examples

`bazel-examples.md` documents Hermetiq configuration for
`github.com/bazelbuild/examples`, with notes for the Go and Rust tutorial
projects. It calls out where the upstream examples need a hermetic LLVM
toolchain before they are remote-execution friendly.

- [bazel-examples.md](bazel-examples.md)

## codex

`codex.md` documents a tested Hermetiq configuration for
`github.com/openai/codex`, including BEP upload, remote cache, remote execution,
and the expected `bazel test //...` validation command.

- [codex.md](codex.md)

## drake

`drake.md` documents a Hermetiq configuration for
`github.com/RobotLocomotion/drake` using the `drake-runner-image` above,
including the required remote execution platform, BEP upload, remote cache,
and remote execution settings. A full `bazel build //...` has not yet passed;
the current status is documented alongside the configuration.

- [drake.md](drake.md)

## envoy

`envoy.md` documents a tested Hermetiq configuration for
`github.com/envoyproxy/envoy`, including Envoy's generated remote execution
platform, the matching Envoy worker pool, BEP upload, remote cache, remote
execution, and the expected `bazelisk build //source/exe:envoy-static`
validation command.

- [envoy.md](envoy.md)
