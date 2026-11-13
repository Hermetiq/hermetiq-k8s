# Scheduler action routing

`scheduler.actionRouter` selects a worker platform, invocation grouping, and
initial size class for each action. Use a custom router when clients send a
platform that needs to map to an existing worker pool while other requests
continue to route normally.

The examples below use illustrative instance names, pool names, and image
references. Replace them with your own configuration.

## Choose a routing mode

| Mode | Matching and default behavior |
| --- | --- |
| `simple` | Uses the client's action platform unchanged. This is the chart default. |
| `demultiplexing` | Keeps the listed `backends` on their original platforms; rewrites every unmatched request to `catchAll.platform.properties`. |
| `custom` | Inserts your Jsonnet router body. Each backend and the default router can have its own platform extractor and scheduling policy. |

The chart's `demultiplexing` shorthand is useful for a general fallback pool.
The custom example here instead rewrites one known client platform and leaves
unmatched requests unchanged.

## How matching and ordering work

Routing happens in two steps: the outer router matches the incoming request,
then the selected inner router produces the key used to find a worker queue.

- **Platform properties must match completely.** Names and values are case
  sensitive. Extra or missing properties, a different image tag or digest, or
  `EstimatedCPU: "2"` instead of `"1"` select a different platform. Matching
  does not treat the backend properties as a subset or interpret resource
  estimates as ranges.
- **Sort properties by name, then value.** This applies to backend platforms,
  static output platforms, and predeclared queues. Uppercase names such as
  `EstimatedCPU` precede lowercase names. The scheduler rejects unsorted
  platforms. The chart validates its structured platform values, but custom
  Jsonnet must also satisfy this requirement.
- **The longest matching instance-name prefix wins for an exact platform.**
  `example/project-a` matches itself and `example/project-a/build`, but not
  `example/project-ab`. An empty prefix matches every instance. Backend array
  order does not set precedence; duplicate prefix/platform pairs are rejected.
- **The default router runs when no backend matches.** A default extractor
  `{ action: {} }` keeps the original platform. A `{ static: ... }` extractor
  replaces the platform used for queue selection.

The `action` extractor reads `Action.platform`; clients must populate that
field, as required by REv2.2 and newer. It does not fall back to properties on
the Command message.

## Rewrite a known client platform

Save this example as `action-routing-values.yaml`. It accepts a BuildBuddy-style
property set under `example/project-a` and schedules it on workers advertising
only `pool=linux-builds`. The `container-image` value is an example string to
match, not an image installed by this configuration.

When adapting an existing release, retain its other predeclared queues: Helm
replaces arrays rather than appending entries from another values file.

```yaml
storage:
  persistence:
    iscc:
      enabled: true

scheduler:
  sizeClassAnalysis:
    enabled: true
  predeclaredPlatformQueues:
    - instanceNamePrefix: example/project-a
      platform:
        - name: pool
          value: linux-builds
      sizeClasses: [1, 2]
  actionRouter:
    mode: custom
    custom: |
      local routerFor(platformKeyExtractor) = {
        simple: {
          platformKeyExtractor: platformKeyExtractor,
          invocationKeyExtractors: [
            { correlatedInvocationsId: {} },
            { toolInvocationId: {} },
          ],
          initialSizeClassAnalyzer: {
            defaultExecutionTimeout: '1800s',
            maximumExecutionTimeout: '7200s',
            feedbackDriven: {
              failureCacheDuration: '86400s',
              historySize: 32,
              pageRank: {
                acceptableExecutionTimeIncreaseExponent: 0.5,
                smallerSizeClassExecutionTimeoutMultiplier: 1.5,
                minimumExecutionTimeout: '10s',
                maximumConvergenceError: 0.002,
              },
            },
          },
        },
      },

      demultiplexing: {
        platformKeyExtractor: { action: {} },
        backends: [{
          instanceNamePrefix: 'example/project-a',
          platform: { properties: [
            { name: 'EstimatedCPU', value: '1' },
            { name: 'EstimatedMemory', value: '2GB' },
            { name: 'container-image', value: 'docker://registry.example.com/build/ubuntu:22.04' },
            { name: 'dockerUser', value: 'nobody' },
            { name: 'network', value: 'off' },
            { name: 'nonroot-workspace', value: 'true' },
            { name: 'pool', value: 'linux-builds' },
          ] },
          actionRouter: routerFor({
            static: { properties: [
              { name: 'pool', value: 'linux-builds' },
            ] },
          }),
        }],
        defaultActionRouter: routerFor({ action: {} }),
      },
```

The backend matches all seven incoming properties. Its static extractor returns
only `pool=linux-builds`, retaining the request's instance name. Queue lookup
then selects the matching predeclared prefix/platform and a configured size
class. Other platforms, including a nearly matching request with a different
`EstimatedCPU`, take the default path unchanged and still need a matching
worker queue.

The static platform rewrite changes the scheduling key; it does not change
`Action.platform` or the action digest. Action Cache entries therefore retain
the client's original platform.
Different incoming platforms do not acquire a shared cache key just because
they route to the same workers.

The rewrite also does not configure the runner image, user, network, or
filesystem. Configure the destination workers to provide the execution
environment expected by those client properties.

## Match queues, workers, and scheduling policy

The example requires workers registered under `example/project-a`, advertising
exactly `pool=linux-builds`, with size classes `1` and `2`. Configure those on
the corresponding `RbeWorker` resources. The chart creates the scheduler's
queues, not worker Deployments. A predeclared queue remains available while
workers scale to zero; a dynamically discovered queue eventually disappears
after its workers leave.

The two classes share one platform. Class `2` must be capable of retrying work
that fails on class `1`. The feedback-driven analyzer needs the Initial Size
Class Cache, which is why the example enables both
`storage.persistence.iscc.enabled` and `scheduler.sizeClassAnalysis.enabled`.
Its short initial attempt can legitimately time out and retry on the larger
class; that is independent of a scheduler rollout.

`routerFor()` keeps invocation grouping, timeouts, and analysis consistent
between the rewrite and default paths. In `mode: custom`, these values are
literal Jsonnet: changing `scheduler.defaultExecutionTimeout`,
`scheduler.maximumExecutionTimeout`, or the chart's PageRank settings does not
edit this custom function. Keep them aligned intentionally. Setting
`scheduler.sizeClassAnalysis.enabled` still controls whether the scheduler
receives its ISCC connection.

For a single-class setup, use matching `sizeClasses: [0]` on the queue and
worker, remove `feedbackDriven` from the custom analyzer, and leave ISCC and
size-class analysis disabled unless other queues use them.

## Add a fallback / catch-all worker pool

Use the chart's `demultiplexing` mode to keep known platforms on their existing
workers and route every unmatched platform to a fallback pool. This alternative
values example keeps requests with exactly `pool=dedicated` on that pool and
rewrites everything else to `pool=fallback`:

```yaml
scheduler:
  predeclaredPlatformQueues:
    - instanceNamePrefix: ""
      platform:
        - name: pool
          value: dedicated
      sizeClasses: [0]
    - instanceNamePrefix: ""
      platform:
        - name: pool
          value: fallback
      sizeClasses: [0]
  actionRouter:
    mode: demultiplexing
    backends:
      - instanceNamePrefix: ""
        platform:
          properties:
            - name: pool
              value: dedicated
    catchAll:
      platform:
        properties:
          - name: pool
            value: fallback
```

The empty prefixes allow these queues to serve every instance name. The
request's instance name remains unchanged. List every platform that should
keep its existing route under `backends`, and preserve the other predeclared
queues when adapting these arrays for an existing release.

Create a separate worker pool in the Buildbarn release namespace. Copy the
[Ubuntu worker manifest](../../../custom-values/rbeworkers/worker-ubuntu22-04.yaml),
retain its runner image, resources, storage, and environment-specific settings,
and change the following fields in the copy:

```yaml
apiVersion: bb.hermetiq.com/v1
kind: RbeWorker
metadata:
  name: worker-fallback
spec:
  config:
    generated:
      instanceNamePrefix: ""
      platformProperties:
        - name: pool
          value: fallback
      sizeClass: 0
```

This is an excerpt to merge into the worker manifest, not a complete worker
definition. Replace its entire `platformProperties` list: retaining the sample's
`container-image` property would produce a different queue key. Keep the
existing dedicated workers advertising exactly `pool=dedicated`, also at size
class `0`. The fallback queue declaration lets its workers scale to zero
without making that platform unknown to the scheduler.

| Incoming platform | Selected worker platform |
| --- | --- |
| `pool=dedicated` | `pool=dedicated` |
| `pool=dedicated` plus an extra property | `pool=fallback` |
| Any other platform, including an empty one | `pool=fallback` |

This is a fallback for **unmatched platforms**, not for busy or empty worker
pools. A matching dedicated request stays queued for its dedicated workers;
the scheduler does not spill it into the fallback pool when those workers are
busy or scaled to zero.

To add the same fallback to the earlier custom rewrite example instead, keep
its specific backend and replace only its default router:

```jsonnet
defaultActionRouter: routerFor({
  static: { properties: [
    { name: 'pool', value: 'fallback' },
  ] },
}),
```

Also add the fallback queue and matching worker configuration shown above.
The custom example's `routerFor()` scheduling policy still applies.

The fallback worker runs its configured environment; an incoming image, user,
or network property does not reconfigure it. Use a catch-all only for workloads
that this environment can execute correctly. A misspelled property can now
reach a worker instead of failing to match, and its result is cached under the
original action digest.

## Render and verify

From the chart repository root, combine the example with your environment's
existing values and inspect the generated configuration:

```bash
helm lint charts/buildbarn -f environment-values.yaml -f action-routing-values.yaml
helm template buildbarn charts/buildbarn --namespace buildbarn \
  -f environment-values.yaml -f action-routing-values.yaml > rendered.yaml
```

With reload disabled, the router is inside `buildbarn-config`'s
`scheduler.jsonnet`. With a compatible scheduler image and
`scheduler.configurationReloadInterval` enabled, it is in
`scheduler-routing.libsonnet`. Helm renders custom Jsonnet as text; a successful
render alone does not establish that the scheduler accepts or can serve it.

Check the destination queue's instance prefix, platform, and size classes in
the scheduler UI or BuildQueueState API. Run one request with the exact input
platform, one with a changed property, and one outside the configured prefix.
Verify the expected queue for each. The
`buildbarn_builder_demultiplexing_action_router_requests_total` counter records
matched backend prefix/platform labels; the default route has empty labels.
Execution logs show the worker that ultimately ran the action.

Action routing works without hot reload or handover. With reload disabled, a
router or queue edit changes the scheduler checksum and rolls the pod. With
reload enabled, supported edits apply after ConfigMap projection and the next
reload interval; an invalid reload keeps the prior configuration. Changes to
an existing queue's size classes still require a rollout. See the
[scheduler feature prerequisites](../README.md#optional-configuration-reload-and-scheduler-handover)
and [queue configuration](../README.md#scheduler).
