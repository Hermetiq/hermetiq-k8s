#!/usr/bin/env bash
# hermetiq-k8s chart PR validation (Phase 5) — runs per chart on non-tag builds.
#
#   helm lint --strict
#   helm template (with the chart's ci-values fixture)
#   kubeconform on the rendered manifests (core kinds; CRDs skipped for now)
#   metadata gates: artifacthub.io/changes present; version bumped if the chart changed
#   helm-unittest (if charts/<chart>/tests/ exists — none authored yet)
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
if ! grep -q 'artifacthub.io/changes' "${DIR}/Chart.yaml"; then
  echo "^^^ +++"
  echo ":x: ${DIR}/Chart.yaml is missing the artifacthub.io/changes annotation" >&2
  exit 1
fi
# Version-bump gate (best-effort: only when we can diff against the PR base): if
# any chart file changed, Chart.yaml version must have been bumped too.
base="${BUILDKITE_PULL_REQUEST_BASE_BRANCH:-}"
# Best-effort refresh of the base ref. The container has no git creds, so this
# may fail — GIT_TERMINAL_PROMPT=0 (above) makes it fail fast instead of hanging.
# Either way, fall back to whatever the agent already fetched during checkout.
if [ -n "${base}" ]; then
  git fetch -q --no-tags origin "${base}" 2>/dev/null || true
fi
mb="$(git merge-base "origin/${base}" HEAD 2>/dev/null || true)"
if [ -n "${mb}" ] && ! git diff --quiet "${mb}" HEAD -- "${DIR}"; then
  if git diff "${mb}" HEAD -- "${DIR}/Chart.yaml" | grep -qE '^\+version:'; then
    echo ":white_check_mark: ${CHART} changed and Chart.yaml version was bumped"
  else
    echo "^^^ +++"
    echo ":x: ${DIR} changed but Chart.yaml version was not bumped" >&2
    exit 1
  fi
fi

echo "+++ :test_tube: helm-unittest"
if [ -d "${DIR}/tests" ]; then
  # Pin the version (see HELM_UNITTEST_VERSION above); no `|| true` — a failed
  # install should fail the step, not silently skip and then error on `unittest`.
  helm plugin install https://github.com/helm-unittest/helm-unittest --version "v${HELM_UNITTEST_VERSION}" >/dev/null
  helm unittest "${DIR}"
else
  echo "(no ${DIR}/tests — skipping; add suites under ${DIR}/tests/ to enable)"
fi

echo "+++ :white_check_mark: ${CHART} validation passed"
