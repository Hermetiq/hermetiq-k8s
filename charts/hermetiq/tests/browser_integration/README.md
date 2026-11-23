# Browser gateway transport regression

Run from the repository root:

```sh
python3 charts/hermetiq/tests/browser_gateway_integration.py
```

Requires Docker, Helm, Python 3 and PyYAML. The test pulls pinned public images
and builds a small Python fixture. The published gRPC proxy image is amd64;
ARM hosts need Docker's amd64 emulation. No Kubernetes cluster or private source
checkout is needed.

The exercised path is real Envoy 1.37.2 → oauth2-proxy → nginx HTTP/1.1 BFF →
Hermetiq gRPC auth proxy → fixture gRPC API. A disposable issuer signs JWTs that
oauth2-proxy and the gRPC proxy verify. The fixture API handles the public RPC
names `admin.v1.AdminService/GetProjects` and `GetUsageMetrics` and supplies
deterministic administrator/viewer responses.

The test renders the Helm chart, consumes its `EnvoyPatchPolicy` operations and
OAuth configuration, and checks:

- Without the policy, both RPCs reproduce HTTP 505 in text and binary gRPC-web.
- With the policy, both return a response and `grpc-status: 0` trailers.
- Missing or invalid JWTs require authentication; a viewer remains denied even
  when it sends forged administrator headers.
- Existing virtual-host filter settings survive the patch, and the separate API
  host retains Envoy's gRPC-web translation.

The patch adapter implements the chart's hostname selector and Envoy Gateway's
JSON `add` behavior, including creation of missing parent objects. The live
Envoy process consumes the resulting configuration. This test does not launch
the Envoy Gateway Kubernetes controller or validate its CRD reconciliation.

The API is explicitly a test fixture: this verifies transport and credential
delivery, not the Hermetiq application's authorization implementation. Validate
production permission semantics separately with matching application images.

Runtime containers use an internal Docker network, nonroot users, read-only
filesystems, resource limits and disposable configuration volumes. No ports or
host directories are exposed. Containers, volumes, network and the fixture
image are removed on completion, including failure.
