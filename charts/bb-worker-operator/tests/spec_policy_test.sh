#!/usr/bin/env bash
# specPolicy values become the operator's RbeWorker spec policy environment.
# Render the manager Deployment with the defaults and with every setting, and
# fail if a default leaks a policy variable or a set value renders wrongly.
set -euo pipefail
chart_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

render() {
  helm template bb-worker-operator "$chart_dir" --namespace hermetiq \
    --show-only templates/deployment.yaml "$@"
}

fail() { echo "spec policy: $*" >&2; exit 1; }

# expect_env <rendered> <name> <value>: the env entry <name> has value <value>.
expect_env() {
  grep -A1 -E "^ +- name: $2\$" <<<"$1" | grep -qxE " +value: \"$3\"" ||
    fail "$2 is not \"$3\""
}

policy_vars='ALLOWED_POD_SERVICE_ACCOUNTS|ALLOW_PRIVILEGED_EXTRA_CONTAINERS|ALLOWED_HOST_PATH_PREFIXES|ALLOWED_CLUSTER_TRIGGER_AUTHENTICATIONS'

# Defaults: no policy variables, and the operator's own ServiceAccount is named.
rendered=$(render)
if grep -qE -- "- name: ($policy_vars)\$" <<<"$rendered"; then
  fail "default render sets a policy variable"
fi
expect_env "$rendered" POD_SERVICE_ACCOUNT bb-worker-operator

# Explicitly empty or false values render the same as the defaults.
rendered=$(render \
  --set-json 'specPolicy.allowedPodServiceAccounts=[]' \
  --set specPolicy.allowPrivilegedExtraContainers=false \
  --set-json 'specPolicy.allowedHostPathPrefixes=[]' \
  --set-json 'specPolicy.allowedClusterTriggerAuthentications=[]')
if grep -qE -- "- name: ($policy_vars)\$" <<<"$rendered"; then
  fail "empty values set a policy variable"
fi

# Every setting: lists join with commas, the boolean renders as "true".
rendered=$(render \
  --set-json 'specPolicy.allowedPodServiceAccounts=["rbe-worker","default"]' \
  --set specPolicy.allowPrivilegedExtraContainers=true \
  --set-json 'specPolicy.allowedHostPathPrefixes=["/mnt/stateful_partition/kube-ephemeral-ssd","/var/cache/bb"]' \
  --set-json 'specPolicy.allowedClusterTriggerAuthentications=["vm-auth"]')
expect_env "$rendered" ALLOWED_POD_SERVICE_ACCOUNTS 'rbe-worker,default'
expect_env "$rendered" ALLOW_PRIVILEGED_EXTRA_CONTAINERS true
expect_env "$rendered" ALLOWED_HOST_PATH_PREFIXES '/mnt/stateful_partition/kube-ephemeral-ssd,/var/cache/bb'
expect_env "$rendered" ALLOWED_CLUSTER_TRIGGER_AUTHENTICATIONS vm-auth

# POD_SERVICE_ACCOUNT follows the ServiceAccount the chart runs the manager as.
rendered=$(render --set serviceAccount.name=bbwo-manager)
expect_env "$rendered" POD_SERVICE_ACCOUNT bbwo-manager
grep -qxE ' +serviceAccountName: bbwo-manager' <<<"$rendered" ||
  fail "manager does not run as bbwo-manager"
rendered=$(render --set serviceAccount.create=false --set serviceAccount.name=external-sa)
expect_env "$rendered" POD_SERVICE_ACCOUNT external-sa

# The schema rejects entries the operator would refuse at startup or split.
if render --set-json 'specPolicy.allowedHostPathPrefixes=["relative/path"]' >/dev/null 2>&1; then
  fail "schema accepted a relative hostPath prefix"
fi
if render --set-json 'specPolicy.allowedPodServiceAccounts=["a,b"]' >/dev/null 2>&1; then
  fail "schema accepted a ServiceAccount entry with a comma"
fi
if render --set specPolicy.allowedHostPathPrefix=/mnt >/dev/null 2>&1; then
  fail "schema accepted an unknown specPolicy key"
fi
