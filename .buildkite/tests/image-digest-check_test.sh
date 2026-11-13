#!/usr/bin/env bash
# Tests for .buildkite/scripts/image-digest-check.sh, the release-tag gate that
# refuses a chart whose Hermetiq registry images have no digest.
#
#   image-digest-check_test.sh [chart...]   # default: every chart
#
# For each chart: the committed values.yaml with every digest filled in must
# pass, blanking any one digest must fail and name it, and when helm is on PATH
# the pinned values must render every Hermetiq registry image as tag@digest.
# Synthetic fixtures cover the parser's edge cases.
set -euo pipefail
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
gate="${repo_root}/.buildkite/scripts/image-digest-check.sh"
registry="us-docker.pkg.dev/hermetiq-cloud/hermetiq-public/"
# Fixture value only: the gate checks shape, never that a digest exists.
fake_digest="sha256:$(printf '0123456789abcdef%.0s' 1 2 3 4)"
work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT
failures=0

fail() {
  echo ":x: $*" >&2
  failures=$((failures + 1))
}

expect_pass() {
  local label=$1 file=$2
  if ! bash "${gate}" "${file}" >"${work}/out" 2>&1; then
    fail "${label}: expected the gate to pass"
    cat "${work}/out" >&2
  fi
}

expect_fail() {
  local label=$1 file=$2 pattern=$3
  if bash "${gate}" "${file}" >"${work}/out" 2>&1; then
    fail "${label}: expected the gate to fail"
  elif ! grep -Eq "${pattern}" "${work}/out"; then
    fail "${label}: failure did not match /${pattern}/"
    cat "${work}/out" >&2
  fi
}

# Every `digest:` / `*Digest:` value in a values file set to the fixture digest.
pin_all() {
  sed -E "s/^([[:space:]]*[A-Za-z]*[Dd]igest:)[[:space:]]*(\"\"|''|\"[^\"]*\"|'[^']*'|[^#[:space:]]*)/\1 \"${fake_digest}\"/" "$1"
}

render_args() {
  case "$1" in
    hermetiq) echo "--set assistant.enabled=true --set assistant.anthropic.apiKey.existingSecret=llm-key" ;;
    buildbarn) echo "--set frontend.grpcCacheProxy.enabled=true" ;;
    *) echo "" ;;
  esac
}

check_chart() {
  local chart=$1 dir="${repo_root}/charts/$1"
  local values="${dir}/values.yaml" pinned="${work}/${chart}-pinned.yaml"

  grep -q "repository: ${registry}" "${values}" \
    || { fail "${chart}: values.yaml has no ${registry} image; nothing to gate"; return; }

  pin_all "${values}" >"${pinned}"
  expect_pass "${chart} with every digest pinned" "${pinned}"

  # Blank each pinned digest in turn; the gate must name that key.
  local n=0 line key blanked="${work}/${chart}-blank.yaml"
  while IFS= read -r line; do
    n=$((n + 1))
    key=$(sed -nE "${line}s/^[[:space:]]*([A-Za-z]*[Dd]igest):.*/\1/p" "${pinned}")
    sed -E "${line}s/^([[:space:]]*[A-Za-z]*[Dd]igest:).*/\1 \"\"/" "${pinned}" >"${blanked}"
    # Digest keys outside a Hermetiq registry image block are not gated.
    if awk -v l="${line}" -v reg="${registry}" 'NR < l && /repository:/ { last = $0 } NR == l { exit !(index(last, reg) > 0) }' "${pinned}"; then
      expect_fail "${chart} with ${key} on line ${line} blank" "${blanked}" "needs sha256 digests for:.* ${key}( |$)"
    fi
  done < <(grep -nE "^[[:space:]]*[A-Za-z]*[Dd]igest: \"${fake_digest}\"" "${pinned}" | cut -d: -f1)
  [[ ${n} -gt 0 ]] || fail "${chart}: no digest fields found to pin"

  if command -v helm >/dev/null 2>&1; then
    local args=(-f "${pinned}")
    [[ -f "${dir}/ci-values/ci.yaml" ]] && args+=(-f "${dir}/ci-values/ci.yaml")
    # shellcheck disable=SC2207
    args+=($(render_args "${chart}"))
    if ! helm template digest-check "${dir}" "${args[@]}" --include-crds >"${work}/${chart}.yaml" 2>"${work}/err"; then
      fail "${chart}: helm template with pinned digests failed"
      cat "${work}/err" >&2
      return
    fi
    local images unpinned
    images=$(grep -E "image: \"?${registry}" "${work}/${chart}.yaml" || true)
    unpinned=$(printf '%s\n' "${images}" | grep -v "@${fake_digest}" | grep . || true)
    [[ -n "${images}" ]] || fail "${chart}: rendered no ${registry} images"
    [[ -z "${unpinned}" ]] || fail "${chart}: rendered images without the pinned digest:
${unpinned}"
  else
    echo "(helm not on PATH; skipping the ${chart} render check)"
  fi
}

check_fixtures() {
  local f="${work}/fixture.yaml"

  cat >"${f}" <<EOF
images:
  app:
    repository: ${registry}app
    tag: v1
EOF
  expect_fail "image with no digest field" "${f}" "images.app: .*app has no digest field"

  cat >"${f}" <<EOF
images:
  app:
    tag: v1
    digest: "sha256:abc"
    repository: ${registry}app
EOF
  expect_fail "short digest, repository after digest" "${f}" "needs sha256 digests for: digest"

  cat >"${f}" <<EOF
images:
  app:
    repository: ${registry}app
    digest: "v1"
EOF
  expect_fail "tag in the digest field" "${f}" "needs sha256 digests for: digest"

  cat >"${f}" <<EOF
images:
  app:
    repository: ${registry}app
    digest: "sha256:$(printf 'ABCDEF0123456789%.0s' 1 2 3 4)"
EOF
  expect_fail "uppercase digest" "${f}" "needs sha256 digests for: digest"

  cat >"${f}" <<EOF
# comment
images:
  app:
    repository: "${registry}app"  # trailing comment
    digest: ${fake_digest} # unquoted
  pinnedWithAt:
    repository: '${registry}other'
    digest: "@${fake_digest}"
  upstream:
    repository: ghcr.io/buildbarn/bb-storage
    digest: ""
EOF
  expect_pass "quoting, comments, @-prefix, third-party image left unpinned" "${f}"

  cat >"${f}" <<EOF
workers:
  - name: a
    image:
      repository: ${registry}runner
      digest: "${fake_digest}"
  - name: b
    image:
      repository: ${registry}runner
      digest: ""
EOF
  expect_fail "second list item unpinned" "${f}" "workers.image: .*runner needs sha256 digests for: digest"

  cat >"${f}" <<EOF
images:
  app:
    repository: ${registry}app
    digest: ""
EOF
  if IMAGE_DIGEST_REGISTRY="example.com/other/" bash "${gate}" "${f}" >/dev/null 2>&1; then :; else
    fail "IMAGE_DIGEST_REGISTRY override: expected an image outside it to pass"
  fi
}

charts=("$@")
[[ ${#charts[@]} -gt 0 ]] || charts=(hermetiq buildbarn bb-worker-operator)

check_fixtures
for chart in "${charts[@]}"; do
  check_chart "${chart}"
done

if [[ ${failures} -gt 0 ]]; then
  echo ":x: image-digest-check: ${failures} failure(s)" >&2
  exit 1
fi
echo "image-digest-check tests passed (${charts[*]})"
