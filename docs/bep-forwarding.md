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

The forwarder acks an event in NATS when the endpoint acknowledges it. For
endpoints such as BuildBuddy that acknowledge only after the whole build,
events stay un-acked within the hold budget described below. After a subscriber
restart or Lease loss, the next leader can re-send a build from its first
event only while that event is still available and un-acked in NATS.

The chart retains un-acked build-tool events for up to **24 hours**
(`buildToolStream.maxAge` in `files/config/nats_streams.json`) with no byte cap.
Acked events are removed once all interested consumers have acked them.
Retention alone does not guarantee replay:

- The default hold budget is **99,500 sent events**, shared across a project's
  builds for each endpoint and partition (`maxAckPending` 100000 minus a fetch
  batch of 500).
  Above it, the largest build releases its held NATS events early. It keeps
  forwarding on a healthy connection but cannot survive a subscriber restart
  or leader change.
- Endpoints that acknowledge each event release those events from NATS as they
  go, so an in-flight build cannot be replayed from its first event after a
  restart once that event has been acked.
- Events older than `maxAge` expire even if un-acked. A build whose first event
  has expired cannot be re-sent.

If an endpoint is down, queued events occupy JetStream disk until delivery,
expiry, or the forwarder's stall timeout. After **30 minutes without send or
ack progress**, the forwarder drops that build and acks its held messages;
it does not wait the full 24 hours for recovery. Size JetStream volumes for
the backlog, or disable the endpoint until it recovers. These forwarding
failures leave an incomplete build at the endpoint; Hermetiq's own copy is
unaffected.

If you supply your own stream ConfigMap (`nats.streamConfig.existingConfigMap`),
keep `buildToolStream.maxAge` at `24h` and `forwarder.consumer.maxAckPending`
at `100000`. Lower values reduce the retention window or hold budget and make
large or long builds more likely to be incomplete after a restart.

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
| `cannot resume partially-forwarded stream ... dropping the remainder` | The build's first event is unavailable: it expired, was released past the hold budget, was already endpoint-acked, or predates forwarding being enabled. That build is incomplete at the endpoint. |
| `made no forwarding progress ... dropping it` | The build made no send or ack progress for 30 minutes. Its remaining events were dropped from forwarding. |
| `cannot start BEP forwarder ... no Kubernetes client` | The subscriber has no ServiceAccount token. See [Requirements](#requirements). |
