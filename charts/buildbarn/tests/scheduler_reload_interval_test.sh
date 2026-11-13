#!/usr/bin/env bash
# Schema errors happen before Helm unit-test assertions can run.
set -euo pipefail

chart_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
error_output="$(mktemp)"
trap 'rm -f "${error_output}"' EXIT

render() {
  helm template reload-interval-test "${chart_dir}" \
    -f "${chart_dir}/ci-values/ci.yaml" \
    --set-string images.scheduler.repository=example.com/bb-scheduler \
    --set-string "scheduler.configurationReloadInterval=$1" \
    --show-only templates/deployment-scheduler.yaml > /dev/null 2> "${error_output}"
}

for interval in "" 30s 0.5s 0.000000001s 315576000000s; do
  if ! render "${interval}"; then
    cat "${error_output}" >&2
    echo "valid reload interval rejected: ${interval}" >&2
    exit 1
  fi
done

for interval in 0s 0.0s 00.000s 1m 500ms 1h -1s 0.0000000001s 315576000001s; do
  if render "${interval}"; then
    echo "invalid reload interval accepted: ${interval}" >&2
    exit 1
  fi
  if ! grep -q 'configurationReloadInterval' "${error_output}"; then
    cat "${error_output}" >&2
    echo "render failed for a reason unrelated to the reload interval" >&2
    exit 1
  fi
done
