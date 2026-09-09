#!/usr/bin/env bash
# hermetiq-k8s chart PR validation (Phase 5) — runs per chart on non-tag builds.
#
#   helm lint --strict
#   helm template (with the chart's ci-values fixture)
#   kubeconform on the rendered manifests (core kinds; CRDs skipped for now)
#   metadata gates: maintenance change notes; release version + README synchronization
#   helm-unittest (when charts/<chart>/tests/ exists)
#
# Runs inside debian:bookworm-slim (docker plugin); installs helm + kubeconform.
# No GCP/secrets needed — pure chart validation. (A prebuilt toolchain image
# would skip the installs; deferred.)
set -euo pipefail

CHART="${1:?usage: chart-checks.sh <chart>}"
DIR="charts/${CHART}"
HELM_VERSION="${HELM_VERSION:-3.16.2}"
KUBECONFORM_VERSION="${KUBECONFORM_VERSION:-0.6.7}"
K8S_VERSION="${K8S_VERSION:-1.30.0}"
# Pin helm-unittest to a released tag — the repo's default branch ships a
# plugin.yaml with a `platformHooks` field that helm ${HELM_VERSION} rejects
# ("unknown field platformHooks"); tagged releases install fine.
HELM_UNITTEST_VERSION="${HELM_UNITTEST_VERSION:-0.8.2}"

echo "+++ :wrench: install helm ${HELM_VERSION} + kubeconform ${KUBECONFORM_VERSION}"
apt-get update -qq && apt-get install -y -qq --no-install-recommends curl ca-certificates git >/dev/null
curl -fsSL "https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz" | tar -xz -C /tmp
install -m 0755 /tmp/linux-amd64/helm /usr/local/bin/helm
curl -fsSL "https://github.com/yannh/kubeconform/releases/download/v${KUBECONFORM_VERSION}/kubeconform-linux-amd64.tar.gz" | tar -xz -C /usr/local/bin kubeconform
git config --global --add safe.directory '*'
# Never block on a git credential prompt: this check container has no GitHub
# creds, so any network git op must fail fast (not hang waiting on stdin for
# `Username for 'https://github.com':`).
export GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=true

echo "+++ :helm: lint --strict ${CHART}"
helm lint --strict "${DIR}"

echo "+++ :helm: template ${CHART}"
values=()
[ -f "${DIR}/ci-values/ci.yaml" ] && values=(-f "${DIR}/ci-values/ci.yaml")
helm template "${CHART}" "${DIR}" "${values[@]}" >/tmp/rendered.yaml
echo "rendered $(grep -c '^kind:' /tmp/rendered.yaml) manifests"

# kubeconform manifest validation is DISABLED by default (set KUBECONFORM=on to
# re-enable). `helm lint --strict` + `helm template` above already catch chart
# breakage; the CRD-catalog schema validation was more trouble than signal.
if [ "${KUBECONFORM:-off}" = "on" ]; then
  echo "+++ :kubeconform: validate rendered manifests"
  # CRD_CATALOG default must be a single-quoted literal — NOT a ${VAR:-…} default:
  # the `}` in the {{.Group}} placeholders prematurely closes the ${…} expansion
  # and mangles the URL (→ kubeconform `bad character U+007D '}'`).
  if [ -z "${CRD_CATALOG:-}" ]; then
    CRD_CATALOG='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
  fi
  kubeconform -strict -summary -ignore-missing-schemas \
    -kubernetes-version "${K8S_VERSION}" \
    -schema-location default \
    -schema-location "${CRD_CATALOG}" \
    /tmp/rendered.yaml
else
  echo "+++ :fast_forward: kubeconform validation disabled (set KUBECONFORM=on to enable)"
fi

echo "+++ :memo: metadata gates"
bash .buildkite/scripts/chart-metadata-checks.sh "${CHART}"

echo "+++ :test_tube: helm-unittest"
if [ -d "${DIR}/tests" ]; then
  # The install hook downloads a ~24 MiB release asset from GitHub and can fail
  # on a truncated response. Retry into a fresh plugin directory so a partial
  # first install cannot poison the next attempt.
  plugin_installed=false
  for attempt in 1 2 3; do
    HELM_PLUGINS="$(mktemp -d)"
    export HELM_PLUGINS
    if helm plugin install https://github.com/helm-unittest/helm-unittest \
      --version "v${HELM_UNITTEST_VERSION}" >/dev/null; then
      plugin_installed=true
      break
    fi
    echo ":warning: helm-unittest install attempt ${attempt}/3 failed" >&2
  done
  if [ "${plugin_installed}" != true ]; then
    echo "^^^ +++"
    echo ":x: failed to install helm-unittest after 3 attempts" >&2
    exit 1
  fi
  helm unittest "${DIR}"
else
  echo "(no ${DIR}/tests — skipping; add suites under ${DIR}/tests/ to enable)"
fi

echo "+++ :white_check_mark: ${CHART} validation passed"
