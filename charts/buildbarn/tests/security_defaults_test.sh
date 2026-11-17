#!/usr/bin/env bash
# Render-level security defaults that helm-unittest cannot express: they need
# the starter values file outside the chart, every routing provider, and the
# validate.yaml failure path. Run from anywhere; needs helm on PATH.
#
#   - no default, CI or starter render routes the scheduler admin UI (:7982)
#   - enabling an rbeWeb route with an allow admin policy fails the render,
#     unless scheduler.adminHttpServers.allowUnauthenticatedRoute opts out
#   - the starter renders the storage and scheduler NetworkPolicies
#   - the scheduler NetworkPolicy admits nothing to :7982 unless adminPeers
#     names a caller, and keeps bb-portal on :8984; an rbeWeb route with that
#     policy and no adminPeers fails the render
#   - frontend.jwks.allowedClientIds requires the claims expression to be
#     exactly true and ANDs the client check onto it; entries with quotes,
#     backslashes or control characters, and a binding without jwks, are
#     rejected
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
chart="$(cd "${here}/.." && pwd)"
repo="$(cd "${chart}/../.." && pwd)"
ci_values="${chart}/ci-values/ci.yaml"
starter="${repo}/custom-values/buildbarn-values.yaml"
providers=(gateway gateway-httproute-only contour ingress none)

failures=0
fail() {
  echo "FAIL: $*" >&2
  failures=$((failures + 1))
}

# gateway.name is required by the gateway providers; it changes nothing else.
render() {
  helm template t "${chart}" --namespace hermetiq --set gateway.name=gw "$@"
}

# Prints the kind of every route-like document whose backend is the scheduler
# (by port 7982, or by Service name: the Ingress refers to the port by name).
admin_routes() {
  awk '
    /^---/ { kind = ""; seen = 0; next }
    /^kind:/ { kind = $2 }
    !seen && (/7982/ || /name: scheduler$/) && (kind == "HTTPRoute" || kind == "HTTPProxy" || kind == "Ingress" || kind == "GRPCRoute") { print kind; seen = 1 }
  '
}

expect_no_admin_route() {
  local label="$1"
  shift
  local out
  if ! out="$(render "$@" 2>&1)"; then
    fail "${label}: render failed: ${out}"
    return
  fi
  if [[ -n "$(admin_routes <<<"${out}")" ]]; then
    fail "${label}: renders a route to the scheduler admin UI :7982"
  fi
}

expect_render_failure() {
  local label="$1" pattern="$2"
  shift 2
  local out
  if out="$(render "$@" 2>&1)"; then
    fail "${label}: render succeeded, expected an error matching '${pattern}'"
    return
  fi
  if ! grep -q -- "${pattern}" <<<"${out}"; then
    fail "${label}: unexpected error: ${out}"
  fi
}

expect_output() {
  local label="$1" needle="$2"
  shift 2
  local out
  if ! out="$(render "$@" 2>&1)"; then
    fail "${label}: render failed: ${out}"
    return
  fi
  if ! grep -qF -- "${needle}" <<<"${out}"; then
    fail "${label}: output lacks: ${needle}"
  fi
}

count_kind() {
  grep -c "^kind: $1\$" || true
}

# --- no public scheduler admin UI by default ---------------------------------
for provider in "${providers[@]}"; do
  expect_no_admin_route "defaults, provider ${provider}" --set "routing.provider=${provider}"
  expect_no_admin_route "ci-values, provider ${provider}" -f "${ci_values}" --set "routing.provider=${provider}"
  expect_no_admin_route "starter, provider ${provider}" -f "${starter}" --set "routing.provider=${provider}"
done
expect_no_admin_route "defaults"
expect_no_admin_route "ci-values" -f "${ci_values}"
expect_no_admin_route "starter" -f "${starter}"

guard="an rbeWeb route would publish the scheduler admin UI"
expect_render_failure "contour rbeWeb with allow" "${guard}" \
  --set routing.provider=contour --set ingress.rbeWeb.enabled=true
expect_render_failure "ingress rbeWeb with allow" "${guard}" \
  --set routing.provider=ingress --set ingress.rbeWeb.enabled=true
expect_render_failure "gateway rbeWeb with allow" "${guard}" \
  --set routing.provider=gateway --set gateway.httpRoutes.rbeWeb.enabled=true
expect_render_failure "httproute-only rbeWeb with empty mode" "${guard}" \
  --set routing.provider=gateway-httproute-only --set gateway.httpRoutes.rbeWeb.enabled=true \
  --set scheduler.adminHttpServers.authenticationPolicy.mode=
expect_render_failure "starter with gateway rbeWeb" "${guard}" \
  -f "${starter}" --set gateway.httpRoutes.rbeWeb.enabled=true

# A route that would not render (wrong provider) is not blocked.
expect_no_admin_route "ingress.rbeWeb under the gateway provider" \
  --set routing.provider=gateway --set ingress.rbeWeb.enabled=true

# Explicit opt-outs still publish the route.
out="$(render --set routing.provider=contour --set ingress.rbeWeb.enabled=true \
  --set scheduler.adminHttpServers.allowUnauthenticatedRoute=true)" \
  || fail "allowUnauthenticatedRoute=true: render failed"
[[ "$(admin_routes <<<"${out}")" == "HTTPProxy" ]] \
  || fail "allowUnauthenticatedRoute=true: expected the rbe-web HTTPProxy"
out="$(render --set routing.provider=ingress --set ingress.rbeWeb.enabled=true \
  --set scheduler.adminHttpServers.allowUnauthenticatedRoute=true)" \
  || fail "allowUnauthenticatedRoute=true, ingress: render failed"
[[ "$(admin_routes <<<"${out}")" == "Ingress" ]] \
  || fail "allowUnauthenticatedRoute=true, ingress: expected the rbe-web Ingress"
out="$(render --set routing.provider=gateway --set gateway.httpRoutes.rbeWeb.enabled=true \
  --set scheduler.adminHttpServers.authenticationPolicy.mode=deny)" \
  || fail "admin mode deny: render failed"
[[ "$(admin_routes <<<"${out}")" == "HTTPRoute" ]] \
  || fail "admin mode deny: expected the rbe-web HTTPRoute"

# A published route behind the scheduler NetworkPolicy needs adminPeers.
expect_render_failure "rbeWeb route with the scheduler policy and no adminPeers" \
  "scheduler.networkPolicy admits no pod to the admin UI" \
  --set routing.provider=gateway --set gateway.httpRoutes.rbeWeb.enabled=true \
  --set scheduler.adminHttpServers.allowUnauthenticatedRoute=true --set scheduler.networkPolicy.enabled=true
out="$(render --set routing.provider=gateway --set gateway.httpRoutes.rbeWeb.enabled=true \
  --set scheduler.adminHttpServers.allowUnauthenticatedRoute=true --set scheduler.networkPolicy.enabled=true \
  --set-json 'scheduler.networkPolicy.adminPeers=[{"namespaceSelector":{"matchLabels":{"kubernetes.io/metadata.name":"envoy-gateway-system"}}}]')" \
  || fail "rbeWeb route with adminPeers: render failed"
[[ "$(admin_routes <<<"${out}")" == "HTTPRoute" ]] \
  || fail "rbeWeb route with adminPeers: expected the rbe-web HTTPRoute"

# --- the starter restricts storage and scheduler gRPC ------------------------
out="$(render -f "${starter}")"
[[ "$(count_kind NetworkPolicy <<<"${out}")" == "2" ]] \
  || fail "starter: expected the storage and scheduler NetworkPolicies"
policies="$(grep -A2 '^kind: NetworkPolicy$' <<<"${out}" || true)"
grep -qx '  name: storage' <<<"${policies}" || fail "starter: no storage NetworkPolicy"
grep -qx '  name: scheduler' <<<"${policies}" || fail "starter: no scheduler NetworkPolicy"
[[ "$(render | count_kind NetworkPolicy)" == "0" ]] \
  || fail "defaults: NetworkPolicies should stay opt-in in the chart"

# Prints each ingress rule of the scheduler NetworkPolicy on one line, so a
# rule's peers and ports can be matched together.
scheduler_rules() {
  render --show-only templates/networkpolicy-scheduler.yaml "$@" | awk '
    /^  ingress:/ { on = 1; next }
    !on || /^ *#/ { next }
    /^    - / { if (rule != "") print rule; rule = "" }
    { gsub(/^ +/, ""); rule = rule " " $0 }
    END { if (rule != "") print rule }
  '
}

expect_rule() {
  local label="$1" rules="$2" pattern="$3"
  grep -qE -- "${pattern}" <<<"${rules}" || fail "${label}: no ingress rule matching '${pattern}' in: ${rules}"
}

for values in "defaults:" "starter:${starter}"; do
  label="${values%%:*}"
  file="${values#*:}"
  args=(--set scheduler.networkPolicy.enabled=true)
  [[ -n "${file}" ]] && args=(-f "${file}" "${args[@]}")
  rules="$(scheduler_rules "${args[@]}")" || { fail "${label}: scheduler policy render failed"; continue; }
  if grep -q 7982 <<<"${rules}"; then
    fail "${label}: scheduler policy admits :7982 with empty adminPeers: ${rules}"
  fi
  expect_rule "${label}: bb-portal keeps :8984" "${rules}" \
    '^ - from: - podSelector: matchLabels: app: bb-portal ports: - port: 8984 '
done
rules="$(scheduler_rules --set scheduler.networkPolicy.enabled=true \
  --set-json 'scheduler.networkPolicy.adminPeers=[{"namespaceSelector":{"matchLabels":{"kubernetes.io/metadata.name":"envoy-gateway-system"}}}]')"
expect_rule "adminPeers admits only the listed peer to :7982" "${rules}" \
  '^ - from: - namespaceSelector: matchLabels: kubernetes.io/metadata.name: envoy-gateway-system ports: - port: 7982 '
[[ "$(grep -c 7982 <<<"${rules}")" == "1" ]] || fail "adminPeers: expected exactly one :7982 rule: ${rules}"

# --- frontend JWT client binding ---------------------------------------------
expect_output "starter binds the Bazel client" \
  '== `true`) && contains(`[\"<bazel-m2m-client-id>\"]`, payload.azp)' -f "${starter}"
expect_output "issuer and audience without a binding render unchanged" \
  "\"payload.iss == 'https://i/' && contains(to_array(payload.aud), 'aud')\"" \
  --set frontend.jwks.enabled=true --set frontend.jwks.issuer=https://i/ --set frontend.jwks.audience=aud
# bb-storage accepts only a literal true; `&&` would return the right operand
# when a custom expression yields any other truthy value.
expect_output "binding requires a custom expression to be true, with a custom claim" \
  '"((payload.custom) == `true`) && contains(`[\"a\",\"b\"]`, payload.cid)"' \
  --set frontend.jwks.enabled=true --set frontend.jwks.claimsValidationExpression=payload.custom \
  --set-json 'frontend.jwks.allowedClientIds=["a","b"]' --set frontend.jwks.clientIdClaim=cid
expect_output "namespaced claim names are quoted" \
  'payload.\"https://example.com/client_id\"' \
  --set frontend.jwks.enabled=true --set-json 'frontend.jwks.allowedClientIds=["a"]' \
  --set frontend.jwks.clientIdClaim=https://example.com/client_id
expect_render_failure "claim names cannot carry quotes" "frontend.jwks.clientIdClaim" \
  --set frontend.jwks.enabled=true --set-json 'frontend.jwks.allowedClientIds=["a"]' \
  --set-json 'frontend.jwks.clientIdClaim="a\"b"'
expect_render_failure "a binding without jwks is refused" "frontend.jwks.enabled=false" \
  --set-json 'frontend.jwks.allowedClientIds=["a"]'
expect_render_failure "client IDs cannot break out of the JSON literal" "frontend.jwks.allowedClientIds entry" \
  --set frontend.jwks.enabled=true --set-json 'frontend.jwks.allowedClientIds=["a`b"]'
# Some helm versions reject the control character while parsing the values
# ("yaml: control characters are not allowed") before validate.yaml runs;
# either rejection keeps it out of the rendered config.
for id in 'a\nb' 'a\rb' 'a\tb' 'a\u0000b' 'a\u001bb' 'a\u007fb'; do
  expect_render_failure "client IDs cannot carry control characters (${id})" \
    "frontend.jwks.allowedClientIds entry\|control characters are not allowed" \
    --set frontend.jwks.enabled=true --set-json "frontend.jwks.allowedClientIds=[\"${id}\"]"
done

if ((failures > 0)); then
  echo "${failures} security default check(s) failed" >&2
  exit 1
fi
echo "security defaults: all checks passed"
