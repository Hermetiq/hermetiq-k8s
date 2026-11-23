#!/usr/bin/env bash
# helm-unittest v0.8.2 cannot assert schema failures: its render pipeline
# returns before failedTemplate assertions. Exercise those guards with Helm.
# Each pattern names the offending field and reason in both Helm 3's
# (gojsonschema) and Helm 4's (santhosh-tekuri/jsonschema) wording.
set -euo pipefail
chart_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output=$(mktemp)
trap 'rm -f "$output"' EXIT
expect_schema_success() {
  local setting=$1
  if ! helm template schema-check "$chart_dir" -f "$chart_dir/ci-values/ci.yaml" \
    --set-json "$setting" >"$output" 2>&1; then
    echo "Expected schema acceptance for $setting:" >&2
    cat "$output" >&2
    exit 1
  fi
}
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
expect_schema_success 'authorization.groupBindings=[{"projectId":"p","issuer":"https://issuer.example","group":"directory-builders","source":"scim","roles":["builder"]},{"projectId":"p","issuer":"https://issuer.example","group":"jwt-builders","source":"jwt","roles":["builder"]},{"projectId":"p","issuer":"https://issuer.example","group":"legacy-builders","roles":["builder"]}]'
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
expect_schema_failure 'publisher.enforceProjectAuthorization="true"' \
  "enforceProjectAuthorization.*(boolean|bool)"
expect_schema_failure 'publisher.jwks.source="automatic"' \
  "source.*(one of|enum)"
expect_schema_failure 'publisher.jwks.refreshInterval="eventually"' \
  "refreshInterval.*(pattern|match)"
expect_schema_failure 'publisher.jwks.principalKind="machine"' \
  "principalKind.*(one of|enum)"
expect_schema_failure 'authorization.defaultAccess="admin"' \
  "defaultAccess.*(one of|enum)"
expect_schema_failure 'authorization.groupBindings=[{"projectId":"p","issuer":"https://issuer.example","group":"engineers","roles":["owner"]}]' \
  "roles.*(one of|enum)"
expect_schema_failure 'authorization.groupBindings=[{"projectId":"p","issuer":"https://issuer.example","group":"engineers","source":"directory","roles":["builder"]}]' \
  "source.*(one of|enum)"
expect_schema_failure 'authorization.serviceAccounts=[{"issuer":"https://issuer.example","subject":"ci"}]' \
  "projectRoles.*required|missing property 'projectRoles'"
expect_schema_failure 'api.scim.token="never-store-provisioning-tokens-in-values"' \
  "token.*(not allowed|additionalProperties)|additional properties.*token"
expect_schema_failure 'api.scim.existingSecretKey="../token"' \
  "existingSecretKey.*(pattern|match)"
expect_schema_failure 'api.scim.groups=[{"id":"build"}]' \
  "displayName.*required|missing property 'displayName'"
echo 'Assistant, RBE, publisher, and authorization values schema checks passed'
