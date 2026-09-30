#!/usr/bin/env bash
# Enforce the chart contribution and release workflow.
#
# Chart change PR:
#   - may increase Chart.yaml to a higher version in the same PR as chart work
#   - updates the root README bundle table to that chart version
#   - may leave chart README OCI commands on the published version
#   - updates artifacthub.io/changes so release notes accumulate
#
# Post-release docs PR:
#   - moves chart README OCI commands to the Chart.yaml version after publication
#
# Tag builds get a final tag/version equality and no-overwrite check in
# publish-chart.sh.
set -euo pipefail

CHART="${1:?usage: chart-metadata-checks.sh <chart>}"
DIR="charts/${CHART}"
CHART_FILE="${DIR}/Chart.yaml"

case "${CHART}" in
  hermetiq)
    BUNDLE_LABEL="Hermetiq"
    ;;
  buildbarn)
    BUNDLE_LABEL="Buildbarn"
    ;;
  bb-worker-operator)
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
  awk -F'|' -v expected="${BUNDLE_LABEL}" '
    /^## Supported chart bundle[[:space:]]*$/ { in_bundle = 1; next }
    in_bundle && /^##[[:space:]]/ { exit }
    in_bundle && NF >= 4 {
      label = $2
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", label)
      if (label == expected) {
        version = $3
        gsub(/[`[:space:]]/, "", version)
        print version
        exit
      }
    }
  ' "$1"
}

# Only consider Helm commands for this chart. Other tools in a chart README
# may also have --version flags (for example, KEDA installation instructions).
read_chart_readme_version() {
  awk -v chart="${CHART}" '
    index($0, "oci://ghcr.io/hermetiq/" chart) { in_command = 1 }
    in_command {
      if (match($0, /--version[[:space:]]+v?[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?/)) {
        version = substr($0, RSTART, RLENGTH)
        sub(/^--version[[:space:]]+v?/, "", version)
        print version
      }
      if ($0 !~ /\\[[:space:]]*$/) in_command = 0
    }
  ' "$1" | sort -u
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
bundle_version="$(read_root_version README.md)"
[[ -n "${bundle_version}" ]] || fail "README.md does not list ${BUNDLE_LABEL} in the supported chart bundle"
[[ "${bundle_version}" == "${current_version}" ]] || fail "README.md lists ${BUNDLE_LABEL} ${bundle_version}; ${CHART_FILE} is ${current_version}"
readme_version="$(read_chart_readme_version "${DIR}/README.md")"
[[ "${readme_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "${DIR}/README.md must use one chart version in its OCI commands"
if [[ "${readme_version}" != "${current_version}" ]] && ! stable_version_is_greater "${current_version}" "${readme_version}"; then
  fail "${DIR}/README.md references ${readme_version}, newer than chart ${current_version}"
fi

if ! current_changes="$(extract_changes "${CHART_FILE}")"; then
  fail "${CHART_FILE} is missing the artifacthub.io/changes block"
fi
current_descriptions="$(printf '%s\n' "${current_changes}" | sed -nE 's/^[[:space:]]*description:[[:space:]]*//p')"
[[ -n "${current_descriptions}" ]] || fail "${CHART_FILE} artifacthub.io/changes has no description"

base="${BUILDKITE_PULL_REQUEST_BASE_BRANCH:-}"
if [[ -z "${base}" || "${base}" == "false" ]]; then
  echo ":white_check_mark: ${CHART} metadata is consistent (chart ${current_version}; chart README OCI version ${readme_version})"
  exit 0
fi

# The checkout normally contains origin/<base>. Refresh when credentials are
# available, but never prompt in the validation container.
git fetch -q --no-tags origin \
  "+refs/heads/${base}:refs/remotes/origin/${base}" 2>/dev/null || true
merge_base="$(git merge-base "origin/${base}" HEAD 2>/dev/null || true)"
[[ -n "${merge_base}" ]] || fail "cannot resolve origin/${base}; refusing to skip chart metadata validation"

base_chart="$(mktemp)"
base_chart_readme="$(mktemp)"
trap 'rm -f "${base_chart}" "${base_chart_readme}"' EXIT
git show "${merge_base}:${CHART_FILE}" >"${base_chart}" 2>/dev/null \
  || fail "cannot read ${CHART_FILE} from the PR base"
git show "${merge_base}:${DIR}/README.md" >"${base_chart_readme}" 2>/dev/null \
  || fail "cannot read ${DIR}/README.md from the PR base"

base_version="$(read_chart_version "${base_chart}")"
base_readme_version="$(read_chart_readme_version "${base_chart_readme}")"
[[ "${base_readme_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "${DIR}/README.md at the PR base has inconsistent OCI versions"

# A chart PR may keep OCI examples on the previously published version or move
# them to the new chart version. A later docs PR can move them once published.
if [[ "${current_version}" != "${base_version}" ]]; then
  if ! stable_version_is_greater "${current_version}" "${base_version}"; then
    fail "${CHART} version changes ${base_version} -> ${current_version}; it must be a higher X.Y.Z version"
  fi
  if [[ "${readme_version}" != "${base_readme_version}" && "${readme_version}" != "${current_version}" ]]; then
    fail "${DIR}/README.md moves from ${base_readme_version} to ${readme_version}; expected ${current_version}"
  fi
elif [[ "${readme_version}" != "${base_readme_version}" ]]; then
  if [[ "${readme_version}" != "${current_version}" ]] || ! stable_version_is_greater "${readme_version}" "${base_readme_version}"; then
    fail "${DIR}/README.md moves from ${base_readme_version} to ${readme_version}; expected chart ${current_version}"
  fi
fi

if git diff --quiet "${merge_base}" HEAD -- "${DIR}"; then
  echo ":white_check_mark: ${CHART} did not change in this PR"
  exit 0
fi
if ! chart_is_release_worthy "${merge_base}"; then
  echo ":white_check_mark: ${CHART} changed, but renders identically to the PR base; no change notes needed"
  exit 0
fi

if [[ "${current_version}" != "${base_version}" ]]; then
  echo ":white_check_mark: ${CHART} PR bumps ${base_version} -> ${current_version}; bundle table and chart README OCI version ${readme_version} are consistent"
  exit 0
fi

base_changes="$(extract_changes "${base_chart}" || true)"
base_descriptions="$(printf '%s\n' "${base_changes}" | sed -nE 's/^[[:space:]]*description:[[:space:]]*//p')"
if [[ "${current_descriptions}" == "${base_descriptions}" ]]; then
  fail "${DIR} changed without a release; update artifacthub.io/changes in ${CHART_FILE} (leave version ${current_version} unchanged)"
fi

echo ":white_check_mark: ${CHART} maintenance PR keeps version ${current_version} and updates artifacthub.io/changes"
