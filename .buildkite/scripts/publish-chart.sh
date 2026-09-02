#!/usr/bin/env bash
# hermetiq-k8s chart publish (Phase 5) — runs on hermetiq-v* / buildbarn-v* tags.
#
# Ports the GitHub Action to Buildkite and hardens it:
#   - verifies the tag version matches charts/<chart>/Chart.yaml
#   - lints + templates the chart (fail fast on a broken chart)
#   - REFUSES to overwrite an already-published OCI version
#   - cosign-signs the pushed chart and self-verifies the signature
#
# Runs inside google/cloud-sdk:slim (docker plugin) with the WIF creds shared in
# (bk-on-prem-helm). It installs helm + cosign and reads ghcr-helm-token +
# cosign-private-key + cosign-password from GCP Secret Manager. (A prebuilt
# toolchain image would be faster, but bk-on-prem-helm has no Artifact Registry
# access, so we stay self-contained on the public base image.)
set -euo pipefail

HELM_VERSION="${HELM_VERSION:-3.16.2}"
COSIGN_VERSION="${COSIGN_VERSION:-2.4.3}"
GCP_PROJECT="hermetiq-cloud"
OCI_HOST="ghcr.io/hermetiq"
OCI_REPO="oci://${OCI_HOST}"
# ghcr PAT auth: the username is largely cosmetic for a classic token, but set
# GHCR_USER to the token owner's GitHub login if registry login is rejected.
GHCR_USER="${GHCR_USER:-hermetiq}"
TAG="${BUILDKITE_TAG:?BUILDKITE_TAG not set — this step only runs on tag builds}"

# --- resolve chart + version from the tag ------------------------------------
case "${TAG}" in
  bb-worker-operator-v*) CHART=bb-worker-operator; VERSION="${TAG#bb-worker-operator-v}" ;;
  hermetiq-v*) CHART=hermetiq; VERSION="${TAG#hermetiq-v}" ;;
  buildbarn-v*) CHART=buildbarn; VERSION="${TAG#buildbarn-v}" ;;
  *)
    echo "^^^ +++"
    echo ":x: ${TAG} is not a hermetiq-v*, buildbarn-v* or bb-worker-operator-v* tag" >&2
    exit 1
    ;;
esac
DIR="charts/${CHART}"
echo "+++ publishing ${CHART} ${VERSION} (tag ${TAG})"

chart_version="$(grep -E '^version:' "${DIR}/Chart.yaml" | head -1 | awk '{print $2}' | tr -d '"')"
if [ "${chart_version}" != "${VERSION}" ]; then
  echo "^^^ +++"
  echo ":x: tag version ${VERSION} != ${DIR}/Chart.yaml version ${chart_version} — bump Chart.yaml or retag" >&2
  exit 1
fi

# --- toolchain (in-script; the cloud-sdk image provides gcloud) --------------
echo "+++ :wrench: install curl + helm ${HELM_VERSION} + cosign ${COSIGN_VERSION}"
apt-get update -qq && apt-get install -y -qq --no-install-recommends curl ca-certificates >/dev/null
curl -fsSL "https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz" | tar -xz -C /tmp
install -m 0755 /tmp/linux-amd64/helm /usr/local/bin/helm
curl -fsSL "https://github.com/sigstore/cosign/releases/download/v${COSIGN_VERSION}/cosign-linux-amd64" -o /usr/local/bin/cosign
chmod 0755 /usr/local/bin/cosign

# --- validate ----------------------------------------------------------------
# lint --strict only; full `helm template` + kubeconform needs ci-values fixtures
# (the chart `required`s runtime values like nats.url) and lands in the separate
# PR-validation slice. `helm package` below still validates the chart packages.
echo "+++ :helm: lint ${CHART}"
helm lint --strict "${DIR}"

# --- read publish secrets from Secret Manager --------------------------------
echo "+++ :gcloud: read publish secrets"
ghcr_token="$(gcloud secrets versions access latest --secret=ghcr-helm-token --project="${GCP_PROJECT}")"
cosign_key="$(mktemp)"
trap 'rm -f "${cosign_key}"' EXIT
gcloud secrets versions access latest --secret=cosign-private-key --project="${GCP_PROJECT}" >"${cosign_key}"
COSIGN_PASSWORD="$(gcloud secrets versions access latest --secret=cosign-password --project="${GCP_PROJECT}")"
export COSIGN_PASSWORD

# --- registry login (helm for push/show, cosign for signing) -----------------
echo "${ghcr_token}" | helm registry login ghcr.io -u "${GHCR_USER}" --password-stdin
echo "${ghcr_token}" | cosign login ghcr.io -u "${GHCR_USER}" --password-stdin

# --- refuse to overwrite an existing version ---------------------------------
if helm show chart "${OCI_REPO}/${CHART}" --version "${VERSION}" >/dev/null 2>&1; then
  echo "^^^ +++"
  echo ":x: ${OCI_HOST}/${CHART}:${VERSION} already exists — refusing to overwrite. Bump Chart.yaml." >&2
  exit 1
fi

# --- package + push + sign ---------------------------------------------------
echo "+++ :helm: package + push ${CHART}:${VERSION}"
helm package "${DIR}" --destination dist/
# tee (not var capture) so the push output — and any error — is visible even when
# push fails: under `set -e`+pipefail a failed `var=$(cmd)` would abort before we
# could echo it.
helm push "dist/${CHART}-${VERSION}.tgz" "${OCI_REPO}" 2>&1 | tee /tmp/helm-push.out
digest="$(grep -oE 'sha256:[0-9a-f]{64}' /tmp/helm-push.out | head -1)"
if [ -z "${digest}" ]; then
  echo "^^^ +++"
  echo ":x: could not parse pushed digest from helm output" >&2
  exit 1
fi
ref="${OCI_HOST}/${CHART}@${digest}"

echo "+++ :cosign: sign + verify ${CHART}:${VERSION}"
cosign sign --yes --key "${cosign_key}" "${ref}"
cosign public-key --key "${cosign_key}" >/tmp/cosign.pub
cosign verify --key /tmp/cosign.pub "${ref}" >/dev/null

echo "+++ :white_check_mark: published + signed ${OCI_HOST}/${CHART}:${VERSION}"
# This script runs inside google/cloud-sdk:slim (docker plugin), which has no
# buildkite-agent binary — skip the annotation there instead of printing a
# confusing "buildkite-agent: command not found" after a SUCCESSFUL publish.
if command -v buildkite-agent >/dev/null 2>&1; then
  buildkite-agent annotate --style success --context "publish-${CHART}" \
    "### :package: Published ${CHART} ${VERSION}
- \`${OCI_HOST}/${CHART}:${VERSION}\` (\`${digest}\`)
- cosign-signed + verified" || true
else
  echo "(no buildkite-agent in this container — skipping the build annotation)"
fi

# A chart's FIRST publish creates a brand-new GHCR package with no access config
# of its own. Charts stay PRIVATE (customers pull with credentials) — so don't
# make it public; instead give it the SAME access as the existing chart packages
# (connect the hermetiq-k8s repo + copy their role/team grants). Until you do,
# every pull 403s with "denied" — GHCR reports that identically for a package you
# can't see and one that doesn't exist, so it looks like the publish never
# happened even when it succeeded.
echo "NOTE: on a chart's FIRST publish, mirror the existing chart packages' access"
echo "      settings onto the new package (keep it private, don't publish it):"
echo "      https://github.com/orgs/hermetiq/packages/container/${CHART}/settings"
