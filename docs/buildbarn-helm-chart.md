# Buildbarn Helm Chart

Hermetiq publishes a maintained **Buildbarn Helm chart** for deploying Buildbarn
remote cache, remote execution, Browser, and related services on Kubernetes.

## Install

```bash
helm upgrade --install buildbarn \
  oci://ghcr.io/hermetiq/buildbarn \
  --version 0.9.6 \
  --namespace hermetiq \
  --values buildbarn-values.yaml
```

Use the [starter values](../custom-values/) and the full
[Buildbarn chart reference](../charts/buildbarn/README.md) for production
configuration. Chart sources live in this repository under
[`charts/buildbarn/`](../charts/buildbarn/).

## Links

- [Artifact Hub package](https://artifacthub.io/packages/helm/hermetiq-buildbarn/buildbarn)
- [OCI chart](https://ghcr.io/hermetiq/buildbarn)
- [Upstream Buildbarn](https://github.com/buildbarn)
- [Repository installation guide](../README.md)
