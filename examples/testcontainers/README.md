# Testcontainers smoke tests on Buildbarn

A minimal Bazel + Go example that proves the Buildbarn Testcontainers worker
fleets are wired up end-to-end. The `RbeWorker` examples support two
Docker-capable pools:

- `pool=testcontainers`: Docker-in-Docker sidecar.
- `pool=testcontainers-sysbox`: Docker daemon inside a Sysbox runner container.

The test code is the same for both pools. The Bazel target sets the
Testcontainers environment variables so the test connects to Docker at
`unix:///var/run/docker.sock`, and target `exec_properties` chooses which
Buildbarn worker fleet runs the Docker-dependent test actions. Your Bazel
invocation still needs a default remote platform for host, toolchain, and other
actions that are not covered by the target's `exec_properties`.

It is modeled on
[bazelbuild/examples/go-tutorial/stage3](https://github.com/bazelbuild/examples/tree/main/go-tutorial/stage3):
one Go library (`redisclient`) plus one test, no binary.

The test (`//redisclient:redisclient_test`) spins up a Redis container via
[testcontainers-go](https://pkg.go.dev/github.com/testcontainers/testcontainers-go),
writes a key, reads it back, and asserts the round-trip. Its BUILD declares
`exec_properties = {"pool": "testcontainers"}` so the Buildbarn scheduler
routes the test target's actions to the DinD Testcontainers worker fleet. The
`requires-docker` tag is also present as informational metadata but is not used
for routing -- see [Troubleshooting](#troubleshooting) below.

If your Buildbarn deployment only has explicitly pooled workers, also set a
default remote platform for actions that do not come from the Docker test
target. For the example on-prem deployment with size-class workers:

```bash
--remote_default_exec_properties=pool=sizeclass
```

For a small smoke test where you intentionally want every remote action to run
on the Docker-capable worker fleet, set the default to `pool=testcontainers` or
`pool=testcontainers-sysbox` instead.

To run the same test on the Sysbox-backed fleet instead, change the target's
`exec_properties` to:

```starlark
exec_properties = {
    "pool": "testcontainers-sysbox",
}
```

Both pools use the same target `env`:

```starlark
env = {
    "DOCKER_HOST": "unix:///var/run/docker.sock",
    "TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE": "/var/run/docker.sock",
    "TESTCONTAINERS_HOST_OVERRIDE": "localhost",
}
```

## Layout

```
examples/testcontainers/
├── .bazelrc
├── .bazelversion
├── MODULE.bazel
├── BUILD                          # gazelle entry point
├── go.mod                         # go.sum is generated locally — see below
├── README.md                      # (this file)
├── redisclient/                   # ── simple Testcontainers smoke test
│   ├── BUILD                      # go_library + go_test
│   ├── redisclient.go             # tiny SET/GET wrapper over go-redis
│   └── redisclient_test.go        # spins up redis:7-alpine, asserts round-trip
└── vespaclient/                   # ── more sophisticated Vespa workflow test
    ├── BUILD                      # go_library + go_test (timeout=long)
    ├── vespaclient.go             # zip/deploy/feed/query helpers over Vespa's HTTP APIs
    ├── vespaclient_test.go        # spins up vespaengine/vespa:8, deploys app, feeds, queries
    └── testapp/                   # minimal Vespa application package (embedded into test)
        ├── services.xml           # single-node services definition
        ├── hosts.xml              # single-host topology
        └── schemas/
            └── doc.sd             # `doc` schema with title + body fields, bm25 ranking
```

## One-time setup

You need Go locally to populate `go.sum` and (optionally) regenerate BUILD
files. Bazel itself does not need a system Go install — `rules_go` provides
a hermetic toolchain.

```bash
cd examples/testcontainers
go mod tidy              # writes go.sum (required by go_deps.from_file)
bazel run //:gazelle     # optional — regenerate BUILD files if you edit imports
```

## Add your RBE config

This example's `.bazelrc` is empty of deployment-specific routing. The test
target chooses the Docker-capable worker pool with `exec_properties`, while
`--remote_default_exec_properties` should point ordinary host/toolchain actions
at a general worker pool. Add a
`--config=rbe` block to your user bazelrc (`~/.bazelrc`), to this project's
`.bazelrc`, or as inline flags. A sketch:

```bazelrc
build:rbe --remote_executor=grpcs://bb.helm.hermetiq.dev:443
build:rbe --remote_instance_name=
build:rbe --remote_timeout=600
build:rbe --grpc_keepalive_time=30s
build:rbe --jobs=64
build:rbe --remote_default_exec_properties=pool=sizeclass
build:rbe --extra_execution_platforms=@rules_go//go/toolchain:linux_amd64
build:rbe --host_platform=@rules_go//go/toolchain:linux_amd64
# build:rbe --tls_client_certificate=...
# build:rbe --tls_client_key=...
```

Use a default pool that exists in your Buildbarn deployment. If you have no
general `pool=sizeclass` workers and are only proving this example, use
`pool=testcontainers` or `pool=testcontainers-sysbox`.

Three of those flags are not optional, and each one fails in a way that looks
like a broken cluster rather than a missing flag:

- **`--remote_default_exec_properties`** — without it, host and toolchain
  actions go out with an empty platform and no pooled worker matches. See
  "`No workers exist ... platform {}`" below.
- **`--remote_timeout=600`** — the default is **60 seconds**, which is not
  enough to upload a large toolchain blob to the Content Addressable Storage
  over a wide-area link. See "the build hangs with idle workers" below.
- **`--grpc_keepalive_time=30s`** — Bazel sends no gRPC keepalive pings by
  default, so if a proxy drops a stream Bazel waits on a dead connection
  instead of retrying.

> **If you put these in a `build:rbe` block, you must actually pass
> `--config=rbe`.** Bazel reads and parses a `build:rbe` block whether or not
> you activate it, and silently ignores every line if you don't. A build that
> reaches remote execution and *then* fails on platform `{}` is the classic
> signature: your `--remote_executor` is coming from somewhere else (a wrapper
> script, `~/.bazelrc`) while the config block sits inert.
>
> To avoid the trap entirely, use plain `build` instead of `build:rbe` — plain
> `build` options are inherited by `test` and `run` and need no `--config`.

Whichever you choose, verify what Bazel actually applied rather than what you
think you set. `--announce_rc` prints a `Found applicable config definition`
line for each config block it *activates* — if that line is missing, your
`build:rbe` options were parsed and then ignored:

```bash
bazel test --announce_rc --config=rbe //redisclient:redisclient_test 2>&1 \
  | grep -E 'applicable config|Reading rc options'
```

The build's own record is the tiebreaker. Open the invocation in the dashboard
(or `GetInvocation` over the Hermetiq MCP server) and compare `cmd_line` against
`unstructured_cmd_line`: options that appear only as
`--default_override=1:build:rbe=...` in the latter were read from your
`.bazelrc` but never applied.

## GKE node pool requirements

The Testcontainers worker fleets should land on dedicated GKE node pools. The
reference GKE setup creates two pools: one for the Docker-in-Docker worker and
one for the Sysbox worker.

For the DinD-backed `worker-testcontainers` `RbeWorker`, create a node pool with:

- GKE image type `UBUNTU_CONTAINERD`.
- Autoscaling enabled, with `minNodeCount: 0`; KEDA can scale the worker
  deployment independently from the node pool.
- Non-spot, non-preemptible nodes.
- A machine type, boot disk size, and local SSD count sized for your
  container-heavy test workload. The reference Pulumi inputs are
  `testcontainersMachineType`, `testcontainersDiskGb`, and
  `testcontainersSsdCount`.
- Workload Identity metadata mode `GKE_METADATA`.
- The node label `workload=testcontainers`.
- The taint `workload=testcontainers:NoSchedule`.

Those last two fields must match `spec.pod` in
`custom-values/rbeworkers/optional/testcontainers/worker-testcontainers.yaml`:

```yaml
pod:
  nodeSelector:
    workload: testcontainers
  tolerations:
    - key: workload
      operator: Equal
      value: testcontainers
      effect: NoSchedule
```

For the Sysbox-backed `worker-testcontainers-sysbox` `RbeWorker`, create a separate
node pool with:

- GKE image type `UBUNTU_CONTAINERD`.
- Autoscaling enabled, with `minNodeCount: 1`; keeping one node warm avoids
  paying the Sysbox install/bootstrap cost on the first test action.
- Non-spot, non-preemptible nodes.
- A machine type, boot disk size, and local SSD count sized for Docker-in-Docker
  style workloads. The reference Pulumi inputs are
  `testcontainersSysboxMachineType`, `testcontainersSysboxDiskGb`, and
  `testcontainersSysboxSsdCount`.
- Workload Identity metadata mode `GKE_METADATA`.
- The node labels `workload=testcontainers-sysbox` and `sysbox-install=yes`.
- The taint `workload=testcontainers-sysbox:NoSchedule`.
- Sysbox installed on the nodes and a Kubernetes `RuntimeClass` named
  `sysbox-runc`.

The matching `RbeWorker` settings are:

```yaml
docker:
  mode: sysbox
  sysbox:
    runtimeClassName: sysbox-runc
    hostUsers: false
pod:
  nodeSelector:
    workload: testcontainers-sysbox
    sysbox-install: "yes"
  tolerations:
    - key: workload
      operator: Equal
      value: testcontainers-sysbox
      effect: NoSchedule
```

The shipped `RbeWorker` examples use `emptyDir` for worker scratch and local
CAS read-cache storage. On GKE, back these nodes with enough ephemeral storage
for Docker layers, test containers, and Buildbarn's read cache. If you switch
the examples to hostPath-backed local SSD, make the path unique per worker pool
and size/schedule pods so two workers do not share one CAS blocks file.

## Run

If this is the only worker pool you have enabled for the smoke test, route all
remote actions to it. For Sysbox:

```bash
bazel test --config=rbe //redisclient:redisclient_test \
  --remote_timeout=600s \
  --remote_default_exec_properties=pool=testcontainers-sysbox \
  --test_output=errors
```

For a mixed deployment, keep the target's `exec_properties` on the
Docker-capable pool, and point ordinary host/toolchain actions at your general
pool:

```bash
bazel test --config=rbe //redisclient:redisclient_test \
  --remote_timeout=600s \
  --remote_default_exec_properties=pool=sizeclass \
  --test_output=errors
```

The simple test:

```bash
bazel test --config=rbe //redisclient:redisclient_test --test_output=errors
```

Expected: passes. The first run will pull `redis:7-alpine` into the DinD
or Sysbox-managed daemon (a few seconds on a warm registry mirror, longer on a
cold node).

The more sophisticated Vespa test:

```bash
bazel test --config=rbe //vespaclient:vespaclient_test --test_output=streamed
```

Expected: passes in roughly 60–120s on a warm Docker daemon (longer on first
run while the `vespaengine/vespa:8` image — ~1.5 GB — pulls). The test:

1. Starts a `vespaengine/vespa:8` container.
2. Waits for the config server on port 19071 to report healthy.
3. Builds an application-package zip from the embedded `testapp/` files
   (services.xml + hosts.xml + schemas/doc.sd).
4. POSTs the zip to `/application/v2/tenant/default/prepareandactivate`.
5. Polls `/ApplicationStatus` on port 8080 until the container service has
   loaded the schema (20–60s post-deploy).
6. Feeds one document via `/document/v1/default/doc/docid/1`.
7. Runs a YQL query (`select * from doc where title contains "hello"`) and
   asserts at least one hit with the expected id.

This is the pattern a real Vespa-using customer would copy: drive Vespa's
HTTP API directly from a test, with the container lifecycle managed by
testcontainers-go. The selected Buildbarn Testcontainers worker pool handles
the Docker daemon.

Tuning for the Vespa test:

- `timeout = "long"` (15 min) in BUILD — Vespa cold-start is genuinely slow.
- Pre-pull the Vespa image via `spec.docker.preloadImages` in the relevant
  `RbeWorker` to skip the ~1.5 GB pull on the first run after a worker pod restart:

  ```yaml
  docker:
    preloadImages:
      - vespaengine/vespa:8
      - redis:7-alpine
      - testcontainers/ryuk:0.6.0
  ```

  Use the same field on `worker-testcontainers-sysbox.yaml` for Sysbox.
- Worker memory: Vespa needs ~3 GB. With `runner.resources.limits.memory: 32Gi`
  (default) and worker `concurrency: 2`, you can run two Vespa tests in
  parallel comfortably.

## Confirming the action landed on the right pool

Two cross-checks:

1. **Bazel-side**, ask Bazel to dump the action's execution info:

   ```bash
   bazel test --config=rbe //redisclient:redisclient_test \
     --execution_log_json_file=/tmp/exec.json
   jq 'select(.targetLabel == "//redisclient:redisclient_test") | .platform' /tmp/exec.json
   ```

   You should see `pool: testcontainers` or `pool: testcontainers-sysbox`
   (and `OSFamily: Linux`) in the platform properties.

2. **Cluster-side**, watch Docker in the selected worker pod.

   DinD:

   ```bash
   POD=$(kubectl -n hermetiq get pod -l instance=testcontainers -o jsonpath='{.items[0].metadata.name}')
   kubectl -n hermetiq exec "$POD" -c dind -- docker ps
   ```

   Sysbox:

   ```bash
   POD=$(kubectl -n hermetiq get pod -l instance=testcontainers-sysbox -o jsonpath='{.items[0].metadata.name}')
   kubectl -n hermetiq exec "$POD" -c runner -- docker ps
   ```

   During the test you should see a `redis:7-alpine` container appear, then
   disappear within a few seconds of the test finishing (Ryuk cleans up).

## Troubleshooting

### First: work out which side is actually stuck

Nearly every failure in this example looks the same from the client — Bazel
prints `N actions, 0 running` with actions sitting at "Ns remote" — and the
instinct is to blame the Docker or Sysbox workers. Usually they are innocent and
idle. Ask the scheduler before you touch a worker:

```bash
kubectl -n hermetiq port-forward svc/scheduler 9980:9980 >/dev/null 2>&1 &
sleep 3
S=http://localhost:9980/metrics
nonzero() { grep "$1" | grep -v '^#' | grep -v ' 0$'; }

# Did any task reach a queue at all?
curl -s $S | nonzero tasks_scheduled_total
# Did Bazel's Execute calls even arrive?
curl -s $S | nonzero 'grpc_server_started_total.*Execute'
# Which platforms have registered workers?
curl -s $S | nonzero workers_created_total
```

The `platform=` label on each series tells you which pool it belongs to, and
`size_class` distinguishes size-class queues.

Read the result like this:

| `workers_created_total` | `Execute` RPCs | `tasks_scheduled_total` | What it means |
|---|---|---|---|
| > 0 for your pool | none | all zero | Bazel never asked for execution. The fault is in your flags or the CAS upload path — **not** the workers. |
| > 0 for your pool | > 0 | > 0, nothing completing | A real worker problem. Check pod logs and `docker ps` inside the runner. |
| none for your pool | any | any | That pool has no workers. Check `RbeWorker` replicas and KEDA. |

The first row is the trap. Workers sitting in a long-poll on
`OperationQueue.Synchronize` with zero removals look suspiciously idle, but that
is exactly what a healthy, unused worker looks like. A worker count of 4 for two
pods is also normal — `bb_worker` registers one worker per `concurrency` slot.

### The build hangs with idle workers, then fails after ~6 minutes

Symptom: actions sit at "Ns remote, 0 running" for minutes, then all of them
fail at once with `UNAVAILABLE: upstream connect error or disconnect/reset
before headers. reset reason: remote reset` and exit code 34.

Cause: `--remote_timeout` defaults to **60 seconds**. If a C++ toolchain ends up
in your graph, `CppCompile [for tool]` actions carry the whole hermetic clang
toolchain in their input root, producing individual CAS blobs of 150–250 MiB.
Over a wide-area link that is more than 60 seconds of upload, so every
`ByteStream.Write` is cancelled just short of finishing. Buildbarn answers
`QueryWriteStatus` with `Unimplemented` — it has no resumable uploads — so each
retry restarts at byte 0 and the upload never converges. `Execute` is never
reached, which is why the workers stay idle.

Fix: set `--remote_timeout=600` and `--grpc_keepalive_time=30s`. Also confirm
the Buildbarn Gateway `BackendTrafficPolicy` keeps `requestTimeout: "0s"` and
`maxStreamDuration: "0s"`.

Confirm the diagnosis from the invocation itself: a `cas_remote_upload_total_ms`
close to the whole build duration, and `bytes_sent` near a gigabyte for a test
that should ship a few megabytes.

### `No workers exist for instance name prefix "0" platform {}`

Target `exec_properties` only decorate actions produced by *that* target. Host
and toolchain actions — `GoToolchainBinaryBuild [for tool]`, external C++, the
protobuf compiler — belong to other targets and go out with an empty platform.
Buildbarn matches platform properties by exact equality on the whole set, so if
every worker advertises an explicit `pool=...`, nothing matches `{}` and you get
`FAILED_PRECONDITION`.

This is Buildbarn working as designed, not a misconfiguration. Fix it by setting
`--remote_default_exec_properties` to a pool that actually exists: `pool=sizeclass`
for a mixed deployment, or `pool=testcontainers-sysbox` when you have
intentionally scaled everything else down.

If you hit this *after* adding the flag, you almost certainly did not pass
`--config=rbe` — see the warning in "Add your RBE config" above.

For a durable fix that cannot be switched off by a forgotten `--config`, put the
properties on an execution platform instead of a command-line flag:

```starlark
platform(
    name = "rbe_linux_amd64",
    parents = ["@rules_go//go/toolchain:linux_amd64"],
    exec_properties = {"pool": "sizeclass"},
)
```

Then point `--extra_execution_platforms` and `--host_platform` at
`//:rbe_linux_amd64`. Target-level `exec_properties` still win per key, so
per-target routing to a Docker pool keeps working. Note that
`--remote_default_exec_properties` applies *only* when the execution platform
declares no `exec_properties` at all, so the two approaches do not stack.

### The build hangs for ~15 minutes, then fails

You routed actions to a pool whose queue is predeclared but has no workers. If
the scheduler config lists the platform under `predeclaredPlatformQueues`, the
queue exists whether or not workers do, so tasks wait instead of failing fast —
until `platformQueueWithNoWorkersTimeout` (900s by default) expires.

Scale the pool up before pointing traffic at it. If the deployment predeclares
`sizeClasses: [1, 2]`, bring up workers for **both** classes: in Buildbarn the
largest size class is responsible for retrying actions that fail on smaller
ones, and an empty smaller class is a black hole for anything the size-class
analyzer routes there.

### A worker pool sits at zero replicas and never scales up

KEDA scaling depends on a Prometheus metric existing. If the metric named in
`spec.autoscaling.prometheus.metricName` was never created as a recording rule,
the query returns no data forever and the pool never leaves zero — which is
self-sustaining, because no workers means no queued tasks means no metric.
Check before trusting it:

```bash
kubectl -n hermetiq port-forward svc/vmselect-vmks 8481:8481 >/dev/null 2>&1 &
curl -s --get http://localhost:8481/select/0/prometheus/api/v1/query \
  --data-urlencode 'query=worker_sizeclass_small_active_or_queued_tasks'
```

An empty `result` array means the metric does not exist, and KEDA is inert: any
replica count you see is `minReplicas` holding the floor, not autoscaling
working. Until the metric exists, set a non-zero `minReplicas` deliberately
rather than relying on scale-up.

Also review `autoscaling.fallback`. A `fallback.replicas: 0` alongside
`minReplicas: 2` means three consecutive scaler *errors* drop the pool to zero
even though you asked for a floor of two — prefer a fallback of 1 so a transient
Prometheus outage cannot silently empty the pool.
`spec.autoscaling.prometheus.query` accepts a raw PromQL expression if you would
rather not add a recording rule.

### Bazel builds protoc and a 1 GB clang toolchain for a pure Go test

If a `bazel test //redisclient:redisclient_test` graph contains thousands of
`CppCompile [for tool]` actions, you are on a stale checkout. An older `go.mod`
here pulled in `github.com/gogo/protobuf`, which dragged the protobuf compiler
into the graph, which in turn required the hermetic LLVM toolchain from
`MODULE.bazel`. The current example builds 243 actions with **zero**
`CppCompile`. Re-sync the example and run `go mod tidy` before debugging
anything else — this is also what makes the `--remote_timeout` problem above
disappear rather than merely become survivable.

### Other things to know

- **`go.sum` missing.** `go_deps.from_file` requires go.sum. Run `go mod tidy`.
- **Don't trust `--modify_execution_info` for tag-based routing.** Despite
  what many blog posts and rules_oci/rules_docker docs suggest, Bazel 9's
  `--modify_execution_info` regex matches against the **action mnemonic
  only**, not against `mnemonic@tag`. A pattern like `.*@requires-docker`
  never matches anything and silently does nothing. If you want tag-based
  pool selection, write a Starlark wrapper macro that propagates the tag
  to `exec_properties`; otherwise put `exec_properties` directly on the
  target as this example does. The same flag *is* the right tool for
  mnemonic-based routing — for example
  `--modify_execution_info=^Cpp.*$=+no-remote-exec` keeps a C++ toolchain
  bootstrap off remote execution while preserving remote caching.
- **Cache-hit rate.** This test will not action-cache meaningfully — the
  container runtime state is not part of the action digest. Expect ~0% hits
  on subsequent runs. That is by design for this pool; use Hermetiq's
  `GetCacheTrends` to confirm it is not a misconfiguration elsewhere.
- **A cold Content Addressable Storage re-uploads everything.** If the CAS
  eviction age is only an hour or two, inputs uploaded by the previous run are
  already gone and each run pays the full upload cost again. Check it with
  Hermetiq's `GetStorageHealth`; an eviction age under 3 hours means the CAS
  blocks device is undersized for your traffic.
- **Queue wait dominates on a small Docker pool.** Pointing
  `--remote_default_exec_properties` at a Testcontainers pool sends every
  ordinary compile through it. With `concurrency: 2` on two pods that is four
  execution slots, and small Go compiles end up spending most of their life
  queued rather than running. Route ordinary actions at a general pool and keep
  the Docker pool for the tests that need Docker.
- **Image pulls.** Pulls happen inside the worker-local Docker daemon, not at
  the node level, so the first run on a fresh pod pays the pull cost. Populate
  `spec.docker.preloadImages` in the relevant `RbeWorker` with the images your
  suite uses most (e.g. `redis:7-alpine`, `postgres:16`,
  `testcontainers/ryuk:0.6.0`) to warm them at pod startup.
