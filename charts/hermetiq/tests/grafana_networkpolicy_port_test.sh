#!/usr/bin/env bash
# The Grafana NetworkPolicy port may be a number or the container port's name.
# helm-unittest cannot assert schema failures, so render with Helm instead.
set -euo pipefail
chart_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output=$(mktemp)
trap 'rm -f "$output"' EXIT

# expect_port <--set-json setting> <expected rendered port line>
expect_port() {
  local setting=$1 expected=$2 got
  got=$(helm template port-check "$chart_dir" -f "$chart_dir/ci-values/ci.yaml" \
    --set-json "$setting" --show-only templates/networkpolicy.yaml |
    sed -n 's/^ *port: //p')
  if [[ "$got" != "$expected" ]]; then
    echo "With $setting expected port: $expected, rendered: ${got:-<none>}" >&2
    exit 1
  fi
}
expect_port 'grafana.networkPolicy.port=3000' '3000'
expect_port 'grafana.networkPolicy.port="grafana"' '"grafana"'

# A digit string would render as an invalid port name, and 0 admits nothing.
for setting in 'grafana.networkPolicy.port="3000"' 'grafana.networkPolicy.port=0' \
  'grafana.networkPolicy.port="Grafana_HTTP"'; do
  if helm template port-check "$chart_dir" -f "$chart_dir/ci-values/ci.yaml" \
    --set-json "$setting" >"$output" 2>&1; then
    echo "Expected schema rejection for $setting" >&2
    exit 1
  fi
  if ! grep -Eq "grafana[./]networkPolicy[./]port" "$output"; then
    echo "Schema rejected $setting without naming grafana.networkPolicy.port:" >&2
    cat "$output" >&2
    exit 1
  fi
done
echo 'Grafana NetworkPolicy port checks passed'
