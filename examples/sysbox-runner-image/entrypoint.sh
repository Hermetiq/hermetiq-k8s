#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -eq 0 ]; then
  set -- /bb/bb_runner /config/runner-testcontainers-sysbox.jsonnet
fi

sudo dockerd \
  --host=unix:///var/run/docker.sock \
  --storage-driver="${DOCKER_STORAGE_DRIVER:-overlay2}" \
  ${DOCKERD_EXTRA_ARGS:-} &
dockerd_pid=$!

cleanup() {
  kill "$dockerd_pid" >/dev/null 2>&1 || true
  wait "$dockerd_pid" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

for _ in $(seq 1 "${DOCKER_READY_ATTEMPTS:-120}"); do
  if docker info >/dev/null 2>&1; then
    sudo chmod 0666 /var/run/docker.sock
    break
  fi
  sleep 1
done

if ! docker info >/dev/null 2>&1; then
  echo "timed out waiting for dockerd readiness" >&2
  exit 1
fi

for image in ${BUILDBARN_PRELOAD_IMAGES:-}; do
  docker pull "$image" || true
done

exec "$@"
