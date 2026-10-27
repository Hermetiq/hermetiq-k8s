#!/usr/bin/env bash
# helm-unittest v0.8.2 cannot assert schema failures: its render pipeline
# returns before failedTemplate assertions. Exercise those guards with Helm.
# Each pattern names the offending field and reason in both Helm 3's
# (gojsonschema) and Helm 4's (santhosh-tekuri/jsonschema) wording.
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
  if ! grep -Eq "$expected" "$output"; then
    echo "Schema rejected $setting without matching /$expected/:" >&2
    cat "$output" >&2
    exit 1
  fi
}
expect_schema_failure 'rbe.accessPolicy.projects={"":{"enabled":true,"minimum_role":"viewer"}}' \
  "Property name of \"\" does not match|invalid propertyName ''"
expect_schema_failure 'rbe.accessPolicy.projects={"0":{"enabled":true,"minimum_role":"owner"}}' \
  "projects\.0\.minimum_role must be one of|projects/0/minimum_role': value must be one of"
expect_schema_failure 'rbe.accessPolicy.projects={"0":{"minimum_role":"viewer"}}' \
  "projects\.0: enabled is required|projects/0': missing property 'enabled'"
expect_schema_failure 'rbe.accessPolicy.projects={"0":{"enabled":"yes","minimum_role":"viewer"}}' \
  "projects\.0\.enabled: Invalid type\. Expected: boolean|projects/0/enabled': got string, want boolean"
expect_schema_failure 'assistant.streamTimeoutSeconds=0' \
  "streamTimeoutSeconds: Must be greater than or equal to 1|streamTimeoutSeconds': minimum: got 0, want 1"
expect_schema_failure 'gateway.timeouts.apiWeb.requestTimeout="five-minutes"' \
  "apiWeb\.requestTimeout: Does not match pattern|apiWeb/requestTimeout': .* does not match pattern"
expect_schema_failure 'gateway.timeouts.mcp.maxStreamDuration="forever"' \
  "mcp\.maxStreamDuration: Does not match pattern|mcp/maxStreamDuration': .* does not match pattern"
echo 'Assistant and RBE values schema checks passed'
