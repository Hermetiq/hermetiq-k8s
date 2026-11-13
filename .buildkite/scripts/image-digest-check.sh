#!/usr/bin/env bash
# Release gate: every default image a chart pulls from Hermetiq's public
# registry must be pinned by digest.
#
#   image-digest-check.sh <values.yaml>
#
# A tag alone resolves at pull time, so whoever can push to the registry
# decides what a default install runs. A digest is fixed when the chart is
# released. The check reads the image blocks in the chart's values.yaml: in any
# mapping whose `repository:` starts with IMAGE_DIGEST_REGISTRY, every tag key
# needs its digest key (`tag` -> `digest`, `apiTag` -> `apiDigest`), so a block
# rendering several images (bepNats: api, pub, sub, bootstrap) cannot pass on
# some of them, and every `*digest:` key must be `sha256:<64 hex>`.
#
# publish-chart.sh runs this on release-tag builds only. Chart PRs keep their
# empty digests while images are still moving; fill them in with the signed
# release digests before tagging (docs/image-integrity.md).
#
# Uses only POSIX awk features so it runs under mawk (debian:bookworm-slim).
set -euo pipefail

VALUES="${1:?usage: image-digest-check.sh <values.yaml>}"
REGISTRY="${IMAGE_DIGEST_REGISTRY:-us-docker.pkg.dev/hermetiq-cloud/hermetiq-public/}"

[[ -f "${VALUES}" ]] || { echo ":x: ${VALUES} not found" >&2; exit 1; }

# One block = the keys sharing an indentation under one parent mapping (or one
# list item). A block is judged when a line with a smaller indentation, or the
# next list item at its level, closes it.
problems="$(awk -v registry="${REGISTRY}" '
  function unquote(v) {
    sub(/^[[:space:]]+/, "", v)
    if (v ~ /^"/) { v = substr(v, 2); sub(/".*$/, "", v); return v }
    if (v ~ /^'\''/) { v = substr(v, 2); sub(/'\''.*$/, "", v); return v }
    sub(/[[:space:]]+#.*$/, "", v)
    sub(/[[:space:]]+$/, "", v)
    return v
  }
  function path(n,   i, p) {
    p = ""
    for (i = 0; i < n; i += 1) if (i in name) p = p (p == "" ? "" : ".") name[i]
    return p == "" ? "(top level)" : p
  }
  function close_block(n,   k, i, want, missing) {
    if (open[n] && repo[n] != "" && index(repo[n], registry) == 1) {
      missing = ""
      k = split(needs[n], want, " ")
      for (i = 1; i <= k; i += 1) if (index(have[n], " " want[i] " ") == 0) missing = missing " " want[i]
      if (ndig[n] == 0) {
        printf "%s: %s has no digest field; missing digest fields:%s\n", path(n), repo[n], missing
      } else if (missing != "") {
        printf "%s: %s missing digest fields:%s\n", path(n), repo[n], missing
      }
      if (bad[n] != "") {
        printf "%s: %s needs sha256 digests for:%s\n", path(n), repo[n], bad[n]
      }
    }
    open[n] = 0; repo[n] = ""; ndig[n] = 0; bad[n] = ""; needs[n] = ""; have[n] = " "
  }
  function close_from(n,   i) {
    for (i = maxind; i >= n; i -= 1) if (open[i]) close_block(i)
  }
  /^[[:space:]]*(#|$)/ { next }
  /^---/ { close_from(0); next }
  {
    line = $0
    match(line, /^ */)
    ind = RLENGTH
    rest = substr(line, ind + 1)
    if (rest ~ /^- /) {
      # A new list item: its keys sit two columns right of the dash.
      ind += 2
      close_from(ind)
      rest = substr(rest, 3)
      sub(/^ +/, "", rest)
    } else {
      close_from(ind + 1)
    }
    if (ind > maxind) maxind = ind
    if (!match(rest, /^[A-Za-z0-9_.-]+:/)) next
    key = substr(rest, 1, RLENGTH - 1)
    value = unquote(substr(rest, RLENGTH + 1))
    open[ind] = 1
    name[ind] = key
    for (i = ind + 1; i <= maxind; i += 1) delete name[i]
    if (key == "repository") repo[ind] = value
    if (!(ind in have)) have[ind] = " "
    # Each image tag needs its digest: tag -> digest, apiTag -> apiDigest.
    if (key == "tag") needs[ind] = needs[ind] " digest"
    else if (key ~ /^[A-Za-z0-9]+Tag$/) needs[ind] = needs[ind] " " substr(key, 1, length(key) - 3) "Digest"
    if (tolower(key) ~ /digest$/) {
      have[ind] = have[ind] key " "
      ndig[ind] += 1
      if (value !~ /^@?sha256:[0-9a-f]+$/ || length(value) != 71 + (value ~ /^@/)) bad[ind] = bad[ind] " " key
    }
  }
  END { close_from(0) }
' "${VALUES}")"

if [[ -n "${problems}" ]]; then
  echo "^^^ +++"
  echo ":x: ${VALUES} publishes ${REGISTRY} images without digests:" >&2
  printf '%s\n' "${problems}" | sed 's/^/  /' >&2
  echo "Set each digest to the signed release image's sha256 digest before tagging (docs/image-integrity.md)." >&2
  exit 1
fi
echo ":white_check_mark: ${VALUES}: every ${REGISTRY} image is pinned by digest"
