# BEP forwarding

Hermetiq can forward every Bazel build it receives to another Build Event
Protocol (BES) endpoint, such as BuildBuddy, while keeping its own copy. Bazel
keeps a single `--bes_backend` pointing at Hermetiq.

## Requirements

- Hermetiq images that include BEP forwarding for on-prem (later than `v0.9.4`).
  Earlier dashboards hide the forwarding settings in on-prem mode.
- `rbac.rules.leases: true` (the default). One subscriber per partition holds a
  Kubernetes Lease and does the forwarding; without the Lease permission no
  forwarder starts.
- `serviceAccount.automountServiceAccountToken: true` (the default), so
  subscribers can reach the Kubernetes API for that Lease.
- Egress from the `bep-nats-sub-*` pods to the endpoint on port 443. The
  forwarder always uses TLS.

## Add an endpoint

1. In the dashboard, open **Project Settings** → **BEP Forward Endpoints** and
   click **Add Endpoint**.
2. Enter the address, for example `remote.buildbuddy.io:443`. A `grpcs://` or
   `grpc://` prefix is accepted and ignored.
3. Add the endpoint's credential as gRPC metadata, for example
   `x-buildbuddy-api-key`. Credential headers (API keys, tokens,
   `authorization`) are always stored as secrets: they are never shown again
   and never logged.
4. Save. Forwarding starts with the next build. Builds already running are not
   forwarded.

Unticking **Enabled** or removing the endpoint stops forwarding and deletes its
NATS consumers. Two endpoints with the same destination are rejected.

## How delivery works

Forwarded events stay un-acked in NATS until the endpoint confirms the whole
build. If a subscriber restarts or loses its Lease mid-build, the next leader
re-sends the build from its first event, and the endpoint shows a complete
build.

This relies on the build-tool stream keeping events long enough. The chart
keeps them **24 hours** (`buildToolStream.maxAge` in
`files/config/nats_streams.json`) with no byte cap. In normal operation the
stream holds only events not yet acked, so it stays small. If an endpoint is
down, its events wait in NATS: size the JetStream volumes for that backlog, or
disable the endpoint until it recovers. A build whose first event is older
than `maxAge` cannot be re-sent and appears incomplete at the endpoint;
Hermetiq's own copy is unaffected.

If you supply your own stream ConfigMap (`nats.streamConfig.existingConfigMap`),
keep `buildToolStream.maxAge` at `24h` and `forwarder.consumer.maxAckPending`
at `100000`. Lower values make large or long builds incomplete at the endpoint
after a restart.

## Troubleshooting

The subscriber logs tell you what happened to each forwarded build:

```bash
kubectl -n hermetiq logs deploy/bep-nats-sub-0 | grep -iE 'forward|stream build_id'
```

| Log message | Meaning |
| --- | --- |
| `... closed after N events` | The build was delivered and confirmed. |
| `... rejected (rpc error: code = PermissionDenied ...); check the endpoint's credentials` | The endpoint refused the credential. Fix the metadata value in Project Settings. |
| `resending N unacknowledged events on reopened stream` | The connection dropped and the build is being re-sent. Expected after network errors or a restart. |
| `handed N held events of M streams back to NATS` | A subscriber stopped and passed its in-flight builds to the next leader. |
| `cannot resume partially-forwarded stream ... dropping the remainder` | The build's first event was no longer in NATS (older than `maxAge`, or forwarding was enabled mid-build). That build is incomplete at the endpoint. |
| `cannot start BEP forwarder ... no Kubernetes client` | The subscriber has no ServiceAccount token. See [Requirements](#requirements). |
