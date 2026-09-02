#!/usr/bin/env bash
# Weekly buildbarn upstream image poller (Phase 5, slice 4).
#
# Checks the ghcr.io/buildbarn/* images referenced by charts/buildbarn/values.yaml
# for newer upstream tags and, if any moved, opens a PR bumping them (+ a patch
# Chart.yaml version bump). It NEVER auto-merges — a human reviews. Runs on a
# weekly Buildkite Scheduled Build (gated `if: build.source == "schedule"`).
#
# Runs in google/cloud-sdk:slim with WIF as bk-on-prem-helm; installs crane + yq.
# Opens the PR via the GitHub App (github-app-id / -private-key from Secret
# Manager) — the app must be installed on this repo with contents+PR write.
set -euo pipefail

GCP_PROJECT="hermetiq-cloud"
REPO="Hermetiq/hermetiq-k8s"
VALUES="charts/buildbarn/values.yaml"
CHART="charts/buildbarn/Chart.yaml"
CRANE_VERSION="${CRANE_VERSION:-0.20.2}"
YQ_VERSION="${YQ_VERSION:-4.44.3}"

# values.yaml tag path | upstream ghcr repo
images=(
  "images.storage.tag|ghcr.io/buildbarn/bb-storage"
  "images.scheduler.tag|ghcr.io/buildbarn/bb-scheduler"
  "images.browser.tag|ghcr.io/buildbarn/bb-browser"
  "images.remoteAsset.tag|ghcr.io/buildbarn/bb-remote-asset"
  "images.worker.tag|ghcr.io/buildbarn/bb-worker"
  "images.runnerInstaller.tag|ghcr.io/buildbarn/bb-runner-installer"
  "frontend.jwks.sync.image.tag|ghcr.io/buildbarn/sync-jwks-to-configmap"
)

echo "+++ :wrench: install crane + yq"
apt-get update -qq && apt-get install -y -qq --no-install-recommends curl ca-certificates git jq openssl >/dev/null
curl -fsSL "https://github.com/google/go-containerregistry/releases/download/v${CRANE_VERSION}/go-containerregistry_Linux_x86_64.tar.gz" | tar -xz -C /usr/local/bin crane
curl -fsSL "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_amd64" -o /usr/local/bin/yq
chmod +x /usr/local/bin/yq
git config --global --add safe.directory '*'

# Newest upstream tag honoring the YYYYMMDDThhmmssZ-<hash> convention. Sort on an
# upper-cased key (tags mix T/t and Z/z) but return the original tag.
newest_tag() {
  crane ls "$1" 2>/dev/null \
    | grep -E '^[0-9]{8}[Tt][0-9]{6}[Zz]-' \
    | awk '{print toupper($0)"\t"$0}' | sort | tail -1 | cut -f2
}

echo "+++ :mag: check upstream buildbarn tags"
declare -a changed=()
for entry in "${images[@]}"; do
  path="${entry%%|*}"
  repo="${entry#*|}"
  current="$(yq ".${path}" "${VALUES}")"
  latest="$(newest_tag "${repo}")"
  if [ -z "${latest}" ]; then
    echo "  ? ${repo}: could not list tags — skipping"
    continue
  fi
  if [ "${latest}" != "${current}" ]; then
    echo "  ↑ ${repo}: ${current} → ${latest}"
    yq -i ".${path} = \"${latest}\"" "${VALUES}"
    changed+=("${repo##*/}: ${current} → ${latest}")
  else
    echo "  = ${repo}: ${current} (current)"
  fi
done

if [ "${#changed[@]}" -eq 0 ]; then
  echo "+++ :white_check_mark: all buildbarn images current — nothing to do"
  exit 0
fi

# Patch-bump the chart version so the PR is releasable as-is.
ver="$(yq '.version' "${CHART}")"
newver="$(echo "${ver}" | awk -F. '{printf "%s.%s.%d", $1, $2, $3 + 1}')"
yq -i ".version = \"${newver}\"" "${CHART}"
echo "+++ bumping buildbarn chart ${ver} → ${newver}"

# --- open a PR via the GitHub App --------------------------------------------
echo "+++ :github: mint app token + open PR"
app_id="$(gcloud secrets versions access latest --secret=github-app-id --project="${GCP_PROJECT}")"
key="$(mktemp)"
trap 'rm -f "${key}"' EXIT
gcloud secrets versions access latest --secret=github-app-private-key --project="${GCP_PROJECT}" >"${key}"

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
now="$(date +%s)"
header="$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)"
payload="$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$((now - 60))" "$((now + 540))" "${app_id}" | b64url)"
sig="$(printf '%s.%s' "${header}" "${payload}" | openssl dgst -sha256 -sign "${key}" -binary | b64url)"
jwt="${header}.${payload}.${sig}"

inst_id="$(curl -fsSL -H "Authorization: Bearer ${jwt}" -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/${REPO}/installation" | jq -r .id)"
token="$(curl -fsSL -X POST -H "Authorization: Bearer ${jwt}" -H "Accept: application/vnd.github+json" \
  "https://api.github.com/app/installations/${inst_id}/access_tokens" | jq -r .token)"

branch="chore/buildbarn-upstream-$(date +%Y%m%d-%H%M%S)"
git config user.email "ci@hermetiq.dev"
git config user.name "hermetiq-ci"
git checkout -b "${branch}"
git add "${VALUES}" "${CHART}"
git commit -m "chore(buildbarn): bump upstream images → chart ${newver}"
git push "https://x-access-token:${token}@github.com/${REPO}.git" "HEAD:${branch}"

{
  echo "Automated buildbarn upstream image bump:"
  echo
  for c in "${changed[@]}"; do echo "- ${c}"; done
  echo
  echo "Chart ${ver} → ${newver}. Review and add an artifacthub.io/changes entry before merging."
} >/tmp/pr-body.txt

curl -fsSL -X POST -H "Authorization: Bearer ${token}" -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/${REPO}/pulls" \
  -d "$(jq -n --arg t "buildbarn: upstream image bump → ${newver}" --arg h "${branch}" --rawfile b /tmp/pr-body.txt \
    '{title: $t, head: $h, base: "main", body: $b}')"

echo "+++ :white_check_mark: opened PR from ${branch}"
