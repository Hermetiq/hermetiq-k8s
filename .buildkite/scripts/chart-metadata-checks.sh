#!/usr/bin/env bash
# Enforce the chart contribution and release workflow.
#
# Maintenance PR:
#   - leaves Chart.yaml version unchanged
#   - changes artifacthub.io/changes so the eventual release notes accumulate
#
# Release PR (signaled by changing Chart.yaml version):
#   - increases the stable SemVer version
#   - updates the pinned version references in the chart and root READMEs
#
# Tag builds get a final tag/version equality and no-overwrite check in
# publish-chart.sh.
set -euo pipefail

CHART="${1:?usage: chart-metadata-checks.sh <chart>}"
DIR="charts/${CHART}"
CHART_FILE="${DIR}/Chart.yaml"

fail() {
  echo "^^^ +++"
  echo ":x: $*" >&2
  exit 1
}

read_chart_version() {
  awk '$1 == "version:" { value=$2; gsub(/["'\'' ]/, "", value); print value; exit }' "$1"
}

extract_changes() {
  awk '
    /^  artifacthub\.io\/changes:[[:space:]]*[|>][-+]?[[:space:]]*$/ {
      found = 1
      in_changes = 1
      next
    }
    in_changes && (/^[^[:space:]]/ || /^  [^[:space:]]/) { exit }
    in_changes {
      sub(/^    /, "")
      print
    }
    END { if (!found) exit 1 }
  ' "$1"
}

stable_version_is_greater() {
  local candidate="$1"
  local previous="$2"
  local candidate_major candidate_minor candidate_patch
  local previous_major previous_minor previous_patch

  [[ "${candidate}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  [[ "${previous}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1

  IFS=. read -r candidate_major candidate_minor candidate_patch <<<"${candidate}"
  IFS=. read -r previous_major previous_minor previous_patch <<<"${previous}"

  ((10#${candidate_major} > 10#${previous_major})) && return 0
  ((10#${candidate_major} < 10#${previous_major})) && return 1
  ((10#${candidate_minor} > 10#${previous_minor})) && return 0
  ((10#${candidate_minor} < 10#${previous_minor})) && return 1
  ((10#${candidate_patch} > 10#${previous_patch}))
}

verify_readme_versions() {
  local version="$1"
  local root_variable bundle_label root_version readme_refs ref ref_version

  case "${CHART}" in
    hermetiq)
      root_variable="HERMETIQ_CHART_VERSION"
      bundle_label="Hermetiq"
      ;;
    buildbarn)
      root_variable="BUILDBARN_CHART_VERSION"
      bundle_label="Buildbarn"
      ;;
    bb-worker-operator)
      root_variable="BB_WORKER_OPERATOR_CHART_VERSION"
      bundle_label="BB Worker Operator"
      ;;
    *) fail "no README version mapping is defined for chart ${CHART}" ;;
  esac

  root_version="$(awk -F= -v key="${root_variable}" '$1 == key { gsub(/[[:space:]]/, "", $2); print $2; exit }' README.md)"
  if [[ "${root_version}" != "${version}" ]]; then
    fail "README.md sets ${root_variable}=${root_version:-<missing>}; release ${CHART} ${version} must update it"
  fi

  if ! grep -Fq "| ${bundle_label} | \`${version}\` |" README.md; then
    fail "README.md supported chart bundle does not list ${bundle_label} ${version}"
  fi

  readme_refs="$(grep -oE -- "--version[[:space:]]+['\"]?v?[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?" "${DIR}/README.md" || true)"
  if [[ -z "${readme_refs}" ]]; then
    fail "${DIR}/README.md has no literal --version reference to validate"
  fi

  while IFS= read -r ref; do
    ref_version="$(printf '%s\n' "${ref}" | sed -E "s/^--version[[:space:]]+['\"]?v?//")"
    if [[ "${ref_version}" != "${version}" ]]; then
      fail "${DIR}/README.md references --version ${ref_version}; release version is ${version}"
    fi
  done <<<"${readme_refs}"
}

[[ -f "${CHART_FILE}" ]] || fail "missing ${CHART_FILE}"

current_version="$(read_chart_version "${CHART_FILE}")"
[[ -n "${current_version}" ]] || fail "${CHART_FILE} has no chart version"

if ! current_changes="$(extract_changes "${CHART_FILE}")"; then
  fail "${CHART_FILE} is missing the artifacthub.io/changes block"
fi
current_descriptions="$(printf '%s\n' "${current_changes}" | sed -nE 's/^[[:space:]]*description:[[:space:]]*//p')"
[[ -n "${current_descriptions}" ]] || fail "${CHART_FILE} artifacthub.io/changes has no description"

# Keeping these references synchronized at all times makes a version change the
# unambiguous release-PR signal and catches partial release edits immediately.
verify_readme_versions "${current_version}"

base="${BUILDKITE_PULL_REQUEST_BASE_BRANCH:-}"
if [[ -z "${base}" || "${base}" == "false" ]]; then
  echo ":white_check_mark: ${CHART} metadata and README versions are internally consistent"
  exit 0
fi

# The checkout normally contains origin/<base>. Refresh when credentials are
# available, but never prompt in the validation container.
git fetch -q --no-tags origin \
  "+refs/heads/${base}:refs/remotes/origin/${base}" 2>/dev/null || true
merge_base="$(git merge-base "origin/${base}" HEAD 2>/dev/null || true)"
[[ -n "${merge_base}" ]] || fail "cannot resolve origin/${base}; refusing to skip chart metadata validation"

if git diff --quiet "${merge_base}" HEAD -- "${DIR}"; then
  echo ":white_check_mark: ${CHART} did not change in this PR"
  exit 0
fi

base_chart="$(mktemp)"
trap 'rm -f "${base_chart}"' EXIT
git show "${merge_base}:${CHART_FILE}" >"${base_chart}" 2>/dev/null \
  || fail "cannot read ${CHART_FILE} from the PR base"

base_version="$(read_chart_version "${base_chart}")"
if [[ "${current_version}" != "${base_version}" ]]; then
  if ! stable_version_is_greater "${current_version}" "${base_version}"; then
    fail "release PR changes ${CHART} version ${base_version} -> ${current_version}; it must be a higher X.Y.Z version"
  fi
  echo ":white_check_mark: ${CHART} release PR bumps ${base_version} -> ${current_version} and updates README versions"
  exit 0
fi

base_changes="$(extract_changes "${base_chart}" || true)"
base_descriptions="$(printf '%s\n' "${base_changes}" | sed -nE 's/^[[:space:]]*description:[[:space:]]*//p')"
if [[ "${current_descriptions}" == "${base_descriptions}" ]]; then
  fail "${DIR} changed without a release; update artifacthub.io/changes in ${CHART_FILE} (leave version ${current_version} unchanged)"
fi

echo ":white_check_mark: ${CHART} maintenance PR keeps version ${current_version} and updates artifacthub.io/changes"
