# Upgrading to the hardened security defaults

The first chart releases after `1.0.0` tighten several security defaults
across the three charts. A new installation that starts from the starter
values in [`custom-values/`](../custom-values/) needs nothing from this
guide. An existing installation should read it before running
`helm upgrade`: some changes refuse to render until you make a choice, and
some change what the cluster lets through without any error.

Each chart's `Chart.yaml` `artifacthub.io/changes` lists the same items;
those that can break an existing installation start with `Breaking:`.

## How your upgrade command decides what changes

- **`helm upgrade -f <your values files>`** (the README's upgrade steps) uses
  the new chart defaults plus your files. New defaults take effect.
- **`helm upgrade --reuse-values`** keeps every value the previous release
  computed, including that release's *defaults*. A setting whose default
  changed keeps its old value. On the Buildbarn chart this means the
  scheduler admin UI route stays enabled, and the render refuses it (see
  below). Pass the updated starter values with `-f`, or set the values below
  explicitly, alongside `--reuse-values`.
- **`helm upgrade --reset-then-reuse-values`** (Helm 3.14 and later) starts
  from the new defaults and applies your previous values on top.

Hardening that lives in the starter values, rather than in chart defaults,
reaches an existing installation only when you adopt those values: the
Buildbarn storage and scheduler NetworkPolicies, the client binding, and the
operator's namespace-scoped RBAC.

## Buildbarn

**Scheduler admin UI route.** `ingress.rbeWeb` and `gateway.httpRoutes.rbeWeb`
are off by default, and the render fails when either would publish the
scheduler admin UI (`:7982`) while
`scheduler.adminHttpServers.authenticationPolicy` is `allow`. The UI can kill
operations and drain workers. Before upgrading, choose one:

- keep it unpublished: set both `ingress.rbeWeb.enabled` and
  `gateway.httpRoutes.rbeWeb.enabled` to `false` (the starter values do), and
  reach it with `kubectl -n <namespace> port-forward svc/scheduler 7982`;
- authenticate the port with a `custom` authentication policy;
- put an authenticating proxy in front of the route and set
  `scheduler.adminHttpServers.allowUnauthenticatedRoute: true`.

**Scheduler NetworkPolicy and `adminPeers`.** With `scheduler.networkPolicy`
enabled, an empty `scheduler.networkPolicy.adminPeers` used to leave `:7982`
open to any pod. It now admits no pod. If anything in the cluster calls the
admin UI directly (a health check, a dashboard, a script), list it in
`adminPeers` before upgrading. A published `rbeWeb` route with an empty list
fails the render.

**Storage and scheduler NetworkPolicies.** The starter values enable
`storage.networkPolicy` and `scheduler.networkPolicy`; the chart defaults stay
off. Before turning them on, list every client of storage (`:8981`) and the
scheduler (`:8982`–`:8984`) beyond the Buildbarn components and `app=worker`
pods, and use a CNI that enforces NetworkPolicy.

**Client binding.** `frontend.jwks.allowedClientIds` limits cache writes and
remote execution to tokens issued to the listed clients. The starter values
enable it with a `<bazel-m2m-client-id>` placeholder, which the render refuses
until you replace it. A wrong or incomplete list does not fail the render: the
frontend starts, cache reads keep working, and every upload and `Execute` from
an unlisted client is denied. Before enabling it, decode a token from every
Bazel client that writes, CI and developer workstations alike, and read the
client claim (`azp` by default; `cid` on Okta, `appid` on Entra ID v1,
`client_id` for RFC 9068 tokens):

```bash
echo '{"uri":"grpcs://bb.<domainBase>"}' | <your Bazel credential helper> get \
  | python3 -c 'import sys,json,base64; t=json.load(sys.stdin)["headers"]["Authorization"][0].split()[1].split(".")[1]; print(json.dumps(json.loads(base64.urlsafe_b64decode(t+"="*(-len(t)%4))),indent=1))'
```

List every client ID you find in `allowedClientIds`, and set
`frontend.jwks.clientIdClaim` if the claim is not `azp`.

## Hermetiq

**BEP route.** The public BEP host forwards only the gRPC services in
`gateway.routes.bepGrpcServices`, by default Bazel's Build Event Service
(`google.devtools.build.v1.PublishBuildEvent`). Buildbarn workers reach the
Completed Action Logger inside the cluster and need no route. If a client
outside the cluster calls another publisher service, add it to the list.

On `routing.provider: ingress`, the BEP route's path uses `pathType:
ImplementationSpecific`, which ingress-nginx treats as a prefix. GCE and AWS
ALB ingress classes treat it as an exact path and answer Bazel's build-event
calls with 404; with those controllers, use `routing.provider: gateway`.

**api-web identity headers.** The public api-web route removes caller-supplied
`X-Forwarded-User`, `X-Forwarded-Email`, `X-Forwarded-Groups`,
`X-Forwarded-Preferred-Username` and `X-Hermetiq-Project-Id` on the Gateway and
Contour providers. If a trusted proxy in front of the route sets these headers,
set `gateway.routes.apiWebRemoveRequestHeaders: []`. On Ingress the removal is
opt-in with `ingress.apiWeb.stripIdentityHeaders: true`, which needs the
ingress-nginx controller to set `allow-snippet-annotations: "true"` and
`annotations-risk-level: Critical`; without them its admission webhook rejects
the upgrade. Otherwise clear the headers in the controller's
`proxy-set-headers` ConfigMap.

**Grafana NetworkPolicy.** While `grafana.oauth2Proxy.enabled` is `true` (the
default), the chart renders `grafana-from-oauth2-proxy`, which admits only
`grafana-oauth2-proxy` and `grafana.networkPolicy.scrapersFrom` (by default
`vmagent` in the release namespace) to the Grafana pods on port `3000`. It
renders even when `gateway.routes.grafanaEnabled` is `false`, because a Grafana
that trusts proxy headers stays exposed after its route is removed. Before
upgrading:

- add any other in-cluster Grafana client, such as another Prometheus scraper
  or a provisioning job, to `scrapersFrom`;
- if you run Grafana yourself without `auth.proxy`, set
  `grafana.oauth2Proxy.enabled: false` (or `grafana.networkPolicy.enabled:
  false`), or the policy leaves it reachable only by the scrapers.

The starter VictoriaMetrics values add a similar policy from that release.
NetworkPolicies are additive, so the broader of the two applies.

## BB Worker Operator

The starter values install the operator namespace-scoped
(`rbac.mode: namespace`) with `metrics.secure: false`. Adopting them replaces
the cluster-wide roles with namespace Roles, and serves metrics over plain
HTTP: the metrics Service port is renamed from `https` to `http`, and the
`metrics-reader` ClusterRole is removed. The chart's own scrape objects
follow; update any other scrape configuration that names the `https` port or
scheme. Namespace mode reconciles RbeWorkers in the operator's namespace only.
