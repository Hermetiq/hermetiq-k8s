#!/usr/bin/env bash
# helm-unittest renders each test on its own, so it can only detect a changed
# rollout checksum by pinning a golden hash. Render twice and compare instead.
set -euo pipefail
chart_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
common=(
  -f "$chart_dir/ci-values/ci.yaml"
  --set assistant.enabled=true
  --set assistant.anthropic.apiKey.existingSecret=anthropic-key
  --set assistant.jev.enabled=true
  --set assistant.jev.apiKey.existingSecret=jev-key
)
inline_policies=(
  --set-json 'assistant.policy.data={"enforcement":{"mode":"shadow"}}'
  --set-json 'rbe.accessPolicy.projects={"0":{"enabled":true,"minimum_role":"viewer"}}'
)
external_policies=(
  --set assistant.policy.existingConfigMap=assistant-policy
  --set rbe.accessPolicy.existingConfigMap=rbe-policy
)

# Prints the named hermetiq.com/<name> pod annotation of the API Deployment.
checksum() {
  local name=$1 value
  shift
  value=$(helm template checksum-check "$chart_dir" "${common[@]}" "$@" \
    --show-only templates/deployment-api.yaml | sed -n "s|^ *hermetiq.com/${name}: ||p")
  [[ -n "$value" ]] || { echo "No hermetiq.com/$name annotation rendered for: $*" >&2; exit 1; }
  printf '%s\n' "$value"
}

# expect <changes|keeps> <annotation> <description> <baseline args> -- <changed args>
expect() {
  local outcome=$1 name=$2 description=$3 before after
  shift 3
  local baseline=()
  while [[ $1 != -- ]]; do baseline+=("$1"); shift; done
  shift
  before=$(checksum "$name" ${baseline[@]+"${baseline[@]}"})
  after=$(checksum "$name" ${baseline[@]+"${baseline[@]}"} "$@")
  if [[ $outcome == changes && $before == "$after" ]]; then
    echo "Expected $name to change when $description" >&2
    exit 1
  fi
  if [[ $outcome == keeps && $before != "$after" ]]; then
    echo "Expected $name to stay the same when $description" >&2
    exit 1
  fi
}

expect changes jev-config-checksum 'the Jev Secret is rotated' \
  -- --set assistant.jev.rolloutChecksum=revision-2
expect keeps jev-config-checksum 'an unrelated API setting changes' \
  -- --set api.replicas=7

expect changes assistant-policy-checksum 'inline policy data changes' "${inline_policies[@]}" \
  -- --set-json 'assistant.policy.data={"enforcement":{"mode":"enforce"}}'
expect changes assistant-policy-checksum 'an external policy is revised' "${external_policies[@]}" \
  -- --set assistant.policy.rolloutChecksum=revision-2
expect keeps assistant-policy-checksum 'the RBE policy changes' "${inline_policies[@]}" \
  -- --set-json 'rbe.accessPolicy.projects={"0":{"enabled":true,"minimum_role":"admin"}}'

expect changes rbe-access-policy-checksum 'an inline project rule changes' "${inline_policies[@]}" \
  -- --set-json 'rbe.accessPolicy.projects={"0":{"enabled":true,"minimum_role":"admin"}}'
expect changes rbe-access-policy-checksum 'an external policy is revised' "${external_policies[@]}" \
  -- --set rbe.accessPolicy.rolloutChecksum=revision-2
expect keeps rbe-access-policy-checksum 'the assistant policy changes' "${inline_policies[@]}" \
  -- --set-json 'assistant.policy.data={"enforcement":{"mode":"enforce"}}'

echo 'Rollout checksum checks passed'
