#!/usr/bin/env bash
# Disposable CI driver. Test workloads run on an isolated Docker network and
# use only generated fixture credentials, never cluster credentials.
set -euo pipefail
HELM_VERSION="${HELM_VERSION:-3.16.2}"
DOCKER_VERSION="${DOCKER_VERSION:-28.5.1}"
apt-get update -qq
apt-get install -y -qq --no-install-recommends ca-certificates curl python3 python3-yaml >/dev/null
curl -fsSL "https://download.docker.com/linux/static/stable/x86_64/docker-${DOCKER_VERSION}.tgz" | tar -xz -C /tmp docker/docker
install -m 0755 /tmp/docker/docker /usr/local/bin/docker
curl -fsSL "https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz" | tar -xz -C /tmp
install -m 0755 /tmp/linux-amd64/helm /usr/local/bin/helm
python3 charts/hermetiq/tests/browser_gateway_integration.py
