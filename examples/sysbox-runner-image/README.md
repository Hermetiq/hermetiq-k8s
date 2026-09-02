# Sysbox Buildbarn runner image

This is an example runner image for the `worker-testcontainers-sysbox` fleet. It
adapts EngFlow's Sysbox guidance to this chart's Buildbarn runner model: Docker
runs inside the runner container, the image includes Buildbarn's `bb_runner`,
and the image entrypoint starts `dockerd` before execing `/bb/bb_runner`.

The Buildbarn chart's normal worker pods install `bb_runner` with a
`bb-runner-installer` init container. The Sysbox pod intentionally does not:
`runtimeClassName` applies to every container in the pod, and the runner image
is the only place that needs `bb_runner`. Baking it into this image keeps the
Sysbox pod simple and avoids running an extra installer container under the
Sysbox runtime.

Build and push the image to a registry reachable by your cluster:

```bash
docker build --platform linux/amd64 -t <registry>/buildbarn-sysbox-runner:latest examples/sysbox-runner-image
docker push <registry>/buildbarn-sysbox-runner:latest
```

The Dockerfile copies `bb_runner` out of Buildbarn's runner-installer image at
build time. Override `RUNNER_INSTALLER_IMAGE` if the chart's
`images.runnerInstaller` tag changes:

```bash
docker build --platform linux/amd64 \
  --build-arg RUNNER_INSTALLER_IMAGE=ghcr.io/buildbarn/bb-runner-installer:<tag> \
  -t <registry>/buildbarn-sysbox-runner:latest \
  examples/sysbox-runner-image
```

Then configure `custom-values/rbeworkers/optional/testcontainers-sysbox/worker-testcontainers-sysbox.yaml`:

```yaml
images:
  runner: <registry>/buildbarn-sysbox-runner:latest

docker:
  mode: sysbox
  sysbox:
    runtimeClassName: sysbox-runc
    hostUsers: false
```

The Kubernetes node pool must have Sysbox installed, and the cluster must expose
a `RuntimeClass` named `sysbox-runc`. On Kubernetes 1.33+ with containerd 2,
Sysbox v0.7 also requires Kubernetes user namespaces (`hostUsers: false`) and
containerd 2.0.5 or newer.

```yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: sysbox-runc
handler: sysbox-runc
```

The operator passes `spec.docker.preloadImages` to the entrypoint as
`BUILDBARN_PRELOAD_IMAGES`. Do not use a `SYSBOX_` prefix for application
settings: Sysbox reserves that namespace for its own runtime options and
rejects unknown names before the container starts.

After deployment, verify Docker is alive inside the runner:

```bash
kubectl -n hermetiq exec -it deploy/worker-testcontainers-sysbox -c runner -- docker info
```
