#!/usr/bin/env bash
# Runs in the pipeline's disposable Debian container with the Docker socket.
# Test containers use disposable named volumes and a private Docker network.
set -euo pipefail
HELM_VERSION="${HELM_VERSION:-3.16.2}"
DOCKER_VERSION="${DOCKER_VERSION:-28.5.1}"
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  ca-certificates curl python3 python3-yaml python3-jsonnet \
  python3-protobuf python3-grpcio >/dev/null
# Bookworm's docker.io client uses API 1.41, below modern daemons' minimum.
# Only the CLI is needed; all containers run on the agent's existing daemon.
curl -fsSL "https://download.docker.com/linux/static/stable/x86_64/docker-${DOCKER_VERSION}.tgz" | tar -xz -C /tmp docker/docker
install -m 0755 /tmp/docker/docker /usr/local/bin/docker
curl -fsSL "https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz" | tar -xz -C /tmp
install -m 0755 /tmp/linux-amd64/helm /usr/local/bin/helm
export BUILDBARN_TEST_CLIENT_CONTAINER="$(hostname)"
python3 charts/buildbarn/tests/storage_integration.py
