#!/usr/bin/env bash
# helm-unittest v0.8.2 cannot assert schema failures: its render pipeline
# returns before failedTemplate assertions. Exercise those guards with Helm.
set -euo pipefail
chart_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output=$(mktemp)
trap 'rm -f "$output"' EXIT
expect_schema_failure() {
  local setting=$1 expected=$2
  if helm template schema-check "$chart_dir" -f "$chart_dir/ci-values/ci.yaml" \
    --set-json "$setting" >"$output" 2>&1; then
    echo "Expected schema rejection for $setting" >&2
    exit 1
  fi
  if ! grep -Fq "$expected" "$output"; then
    cat "$output" >&2
    exit 1
  fi
}
expect_schema_failure 'rbe.accessPolicy.projects={"":{"enabled":true,"minimum_role":"viewer"}}' 'specifications of the schema'
expect_schema_failure 'rbe.accessPolicy.projects={"0":{"enabled":true,"minimum_role":"owner"}}' 'minimum_role'
expect_schema_failure 'rbe.accessPolicy.projects={"0":{"minimum_role":"viewer"}}' 'enabled'
expect_schema_failure 'rbe.accessPolicy.projects={"0":{"enabled":"yes","minimum_role":"viewer"}}' 'enabled'
expect_schema_failure 'assistant.streamTimeoutSeconds=0' 'streamTimeoutSeconds'
echo 'Assistant and RBE values schema checks passed'
