#!/usr/bin/env bash
# Enforce the chart contribution and release workflow.
#
# Next-version PR:
#   - increases Chart.yaml version after a release
#   - leaves README pins on the version that is actually published
#
# Maintenance PR:
#   - leaves Chart.yaml and README versions unchanged
#   - changes artifacthub.io/changes so the eventual release notes accumulate
#
# Post-release docs PR:
#   - moves the README pins to the Chart.yaml version after OCI publication
#
# Tag builds get a final tag/version equality and no-overwrite check in
# publish-chart.sh.
set -euo pipefail

CHART="${1:?usage: chart-metadata-checks.sh <chart>}"
DIR="charts/${CHART}"
CHART_FILE="${DIR}/Chart.yaml"

case "${CHART}" in
  hermetiq)
    ROOT_VARIABLE="HERMETIQ_CHART_VERSION"
    BUNDLE_LABEL="Hermetiq"
    ;;
  buildbarn)
    ROOT_VARIABLE="BUILDBARN_CHART_VERSION"
    BUNDLE_LABEL="Buildbarn"
    ;;
  bb-worker-operator)
    ROOT_VARIABLE="BB_WORKER_OPERATOR_CHART_VERSION"
    BUNDLE_LABEL="BB Worker Operator"
    ;;
  *)
    echo ":x: no README version mapping is defined for chart ${CHART}" >&2
    exit 1
    ;;
esac

fail() {
  echo "^^^ +++"
  echo ":x: $*" >&2
  exit 1
}

read_chart_version() {
  awk '$1 == "version:" { value=$2; gsub(/["'\'' ]/, "", value); print value; exit }' "$1"
}

read_root_version() {
  awk -F= -v key="${ROOT_VARIABLE}" \
    '$1 == key { gsub(/[[:space:]]/, "", $2); print $2; exit }' "$1"
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
  local root_version bundle_version readme_refs ref ref_version

  root_version="$(read_root_version README.md)"
  if [[ "${root_version}" != "${version}" ]]; then
    fail "README.md sets ${ROOT_VARIABLE}=${root_version:-<missing>}; expected released version ${version}"
  fi

  bundle_version="$(awk -F'|' -v expected="${BUNDLE_LABEL}" '
    NF >= 4 {
      label = $2
      gsub(/^[[:space:]]+/, "", label)
      gsub(/[[:space:]]+$/, "", label)
      if (label == expected) {
        pinned = $3
        gsub(/[`[:space:]]/, "", pinned)
        print pinned
        exit
      }
    }
  ' README.md)"
  if [[ "${bundle_version}" != "${version}" ]]; then
    fail "README.md supported chart bundle lists ${BUNDLE_LABEL} ${bundle_version:-<missing>}; released version is ${version}"
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

# Whether this PR changed anything about ${CHART} that a user of the published
# package could observe.
#
# The path test this replaced asked whether any FILE under charts/<name>/
# changed, which is a much broader question: README.md, docs/, LICENSE,
# ci-values/ and tests/ all live under there, and so do comments. A commit
# changing zero non-comment lines was still made to invent an Artifact Hub
# release note for itself, and a note nobody can act on is worse than none —
# it trains readers to skim the changelog.
#
# Three things reach a user, each checked on its own terms:
#
#   1. the rendered manifests, compared with the SAME inputs on both sides, so
#      that editing ci-values/ is not mistaken for editing the chart;
#   2. values.schema.json, which gates what a user may set — a tightened enum
#      rejects values that used to install while rendering identically;
#   3. values.yaml defaults, compared ignoring comments, because ci-values can
#      mask a changed default from the render comparison.
#
# Fails toward requiring notes: if anything cannot be determined — no helm, the
# chart is new, either render fails — the answer is "release-worthy".
render_chart() {
  local dir="$1" out="$2"
  local values=()
  # HEAD's ci-values on BOTH sides. Using each side's own would report a
  # ci-values edit as a chart change: the same category error as the path test.
  [ -f "${DIR}/ci-values/ci.yaml" ] && values=(-f "${DIR}/ci-values/ci.yaml")
  # --include-crds, or a CRD change renders as nothing: helm omits crds/ by
  # default, and bb-worker-operator ships its CRD there.
  #
  # ${values[@]+"${values[@]}"} rather than "${values[@]}": under `set -u`,
  # bash 3.2 treats an empty array expansion as an unbound variable and kills
  # the script. CI runs bash 5 where it is harmless, so the plain form works
  # there and fails only when someone runs this on a Mac — the worst place for
  # a check to behave differently.
  helm template "${CHART}" "${dir}" ${values[@]+"${values[@]}"} --include-crds >"${out}" 2>/dev/null
}

# values.yaml with full-line comments and blank lines removed. Trailing comments
# are deliberately kept: a `#` inside a quoted value is not a comment, and
# over-reporting is the safe direction.
values_without_comments() {
  git show "${1}:${DIR}/values.yaml" 2>/dev/null | grep -vE '^[[:space:]]*(#|$)' || true
}

# Callers check "nothing under the chart was touched" first, so reaching here
# means some file changed and the question is whether it can be observed.
chart_is_release_worthy() {
  local base_ref="$1"

  if ! command -v helm >/dev/null 2>&1; then
    echo "  helm not on PATH; cannot compare rendered output"
    return 0
  fi

  if ! git diff --quiet "${base_ref}" HEAD -- "${DIR}/values.schema.json"; then
    echo "  values.schema.json changed: a schema edit changes what installs, not what renders"
    return 0
  fi

  if [ "$(values_without_comments "${base_ref}")" != "$(values_without_comments HEAD)" ]; then
    echo "  values.yaml defaults changed"
    return 0
  fi

  local base_tree base_out head_out
  base_tree="$(mktemp -d)"
  base_out="$(mktemp)"
  head_out="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -rf '${base_tree}' '${base_out}' '${head_out}'" RETURN

  if ! git archive "${base_ref}" "${DIR}" 2>/dev/null | tar -x -C "${base_tree}" 2>/dev/null; then
    echo "  ${CHART} does not exist at the PR base"
    return 0
  fi
  if ! render_chart "${base_tree}/${DIR}" "${base_out}" || ! render_chart "${DIR}" "${head_out}"; then
    echo "  could not render both sides; treating ${CHART} as changed"
    return 0
  fi
  if cmp -s "${base_out}" "${head_out}"; then
    return 1
  fi
  echo "  rendered output differs from the PR base"
  return 0
}

[[ -f "${CHART_FILE}" ]] || fail "missing ${CHART_FILE}"

current_version="$(read_chart_version "${CHART_FILE}")"
[[ -n "${current_version}" ]] || fail "${CHART_FILE} has no chart version"
released_version="$(read_root_version README.md)"
[[ -n "${released_version}" ]] || fail "README.md does not set ${ROOT_VARIABLE}"

if ! current_changes="$(extract_changes "${CHART_FILE}")"; then
  fail "${CHART_FILE} is missing the artifacthub.io/changes block"
fi
current_descriptions="$(printf '%s\n' "${current_changes}" | sed -nE 's/^[[:space:]]*description:[[:space:]]*//p')"
[[ -n "${current_descriptions}" ]] || fail "${CHART_FILE} artifacthub.io/changes has no description"

# All documentation pins must agree with each other, but Chart.yaml is allowed
# to be ahead while it represents the next, not-yet-published release.
verify_readme_versions "${released_version}"

base="${BUILDKITE_PULL_REQUEST_BASE_BRANCH:-}"
if [[ -z "${base}" || "${base}" == "false" ]]; then
  echo ":white_check_mark: ${CHART} metadata is consistent (chart ${current_version}; published README pin ${released_version})"
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
if ! chart_is_release_worthy "${merge_base}"; then
  echo ":white_check_mark: ${CHART} changed, but renders identically to the PR base; no change notes needed"
  exit 0
fi

base_chart="$(mktemp)"
base_readme="$(mktemp)"
trap 'rm -f "${base_chart}" "${base_readme}"' EXIT
git show "${merge_base}:${CHART_FILE}" >"${base_chart}" 2>/dev/null \
  || fail "cannot read ${CHART_FILE} from the PR base"
git show "${merge_base}:README.md" >"${base_readme}" 2>/dev/null \
  || fail "cannot read README.md from the PR base"

base_version="$(read_chart_version "${base_chart}")"
base_released_version="$(read_root_version "${base_readme}")"

# Moving the README pin is the post-release documentation step. It may only
# move to the chart version, and that chart version must be newer than the
# previously documented release.
if [[ "${released_version}" != "${base_released_version}" ]]; then
  if [[ "${released_version}" != "${current_version}" ]]; then
    fail "README.md moves ${CHART} to ${released_version}, but ${CHART_FILE} is ${current_version}"
  fi
  if ! stable_version_is_greater "${current_version}" "${base_released_version}"; then
    fail "README.md release pin ${base_released_version} -> ${current_version} must increase to a higher X.Y.Z version"
  fi
  echo ":white_check_mark: ${CHART} post-release docs move README pins ${base_released_version} -> ${current_version}"
  exit 0
fi

# A Chart.yaml-only version bump establishes the next development version while
# README pins deliberately stay on the package customers can currently pull.
if [[ "${current_version}" != "${base_version}" ]]; then
  if ! stable_version_is_greater "${current_version}" "${base_version}"; then
    fail "next-version PR changes ${CHART} version ${base_version} -> ${current_version}; it must be a higher X.Y.Z version"
  fi
  other_chart_files="$(git diff --name-only "${merge_base}" HEAD -- "${DIR}" | grep -vxF "${CHART_FILE}" || true)"
  if [[ -n "${other_chart_files}" ]]; then
    fail "${CHART} version bumps belong in a dedicated next-version PR; this PR also changes ${other_chart_files//$'\n'/, }"
  fi
  other_chart_yaml_changes="$(
    git diff --unified=0 "${merge_base}" HEAD -- "${CHART_FILE}" \
      | grep -E '^[+-]' \
      | grep -vE '^(---|\+\+\+|[-+]version:[[:space:]])' \
      || true
  )"
  if [[ -n "${other_chart_yaml_changes}" ]]; then
    fail "${CHART} next-version PR must change only the top-level version in ${CHART_FILE}"
  fi
  echo ":white_check_mark: ${CHART} next-version PR bumps ${base_version} -> ${current_version}; README stays on published ${released_version}"
  exit 0
fi

base_changes="$(extract_changes "${base_chart}" || true)"
base_descriptions="$(printf '%s\n' "${base_changes}" | sed -nE 's/^[[:space:]]*description:[[:space:]]*//p')"
if [[ "${current_descriptions}" == "${base_descriptions}" ]]; then
  fail "${DIR} changed without a release; update artifacthub.io/changes in ${CHART_FILE} (leave version ${current_version} unchanged)"
fi

echo ":white_check_mark: ${CHART} maintenance PR keeps version ${current_version} and updates artifacthub.io/changes"
