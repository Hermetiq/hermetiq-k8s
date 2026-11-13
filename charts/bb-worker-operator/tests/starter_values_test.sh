#!/usr/bin/env bash
# The installation guide installs a namespace-scoped operator from the
# repository's starter values. Render the chart with those values and fail if
# they would grant the operator cluster-scoped RBAC.
set -euo pipefail
chart_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
starter="$chart_dir/../../custom-values/bb-worker-operator-values.yaml"

rendered=$(helm template bb-worker-operator "$chart_dir" --namespace hermetiq -f "$starter")

fail() { echo "starter values: $*" >&2; exit 1; }

if grep -qE '^kind: (ClusterRole|ClusterRoleBinding)$' <<<"$rendered"; then
  fail "render contains a ClusterRole or ClusterRoleBinding"
fi
grep -qE '^kind: RoleBinding$' <<<"$rendered" || fail "render has no manager RoleBinding"
grep -qF -- '--watch-namespace=hermetiq' <<<"$rendered" || fail "manager watch is not scoped to hermetiq"
