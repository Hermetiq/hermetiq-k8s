#!/usr/bin/env bash
set +x
set -euo pipefail

# Creates or reuses the Dex and shared OAuth Secrets in the hermetiq namespace.
# Run after creating the namespace, Gateway, DNS, and TLS for this installation.
namespace=hermetiq
domain_base=${DEX_DOMAIN_BASE:-helm.hermetiq.dev}
gateway_name=${DEX_GATEWAY_NAME:-hermetiq-gateway}
issuer="https://dex.$domain_base"
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
kubectl_context=()
helm_context=()
if [[ -n ${KUBE_CONTEXT:-} ]]; then
  kubectl_context=(--context "$KUBE_CONTEXT")
  helm_context=(--kube-context "$KUBE_CONTEXT")
fi

if [[ ! "$domain_base" =~ ^[a-z0-9][a-z0-9.-]*[a-z0-9]$ || "$domain_base" != *.* ]]; then
  printf 'DEX_DOMAIN_BASE must be a lowercase DNS domain, for example helm.hermetiq.dev.\n' >&2
  exit 1
fi
if [[ ! "$gateway_name" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
  printf 'DEX_GATEWAY_NAME must be a Kubernetes resource name.\n' >&2
  exit 1
fi

for command in kubectl helm htpasswd openssl uuidgen; do
  command -v "$command" >/dev/null || { printf 'Missing command: %s\n' "$command" >&2; exit 1; }
done

kubectl "${kubectl_context[@]}" get namespace "$namespace" >/dev/null
kubectl "${kubectl_context[@]}" -n "$namespace" get gateway "$gateway_name" >/dev/null

secrets_present=0
for name in dex-config dex-client oauth2-proxy-client; do
  if kubectl "${kubectl_context[@]}" -n "$namespace" get secret "$name" >/dev/null 2>&1; then
    secrets_present=$((secrets_present + 1))
  fi
done

if (( secrets_present == 3 )); then
  existing_config=$(kubectl "${kubectl_context[@]}" -n "$namespace" get secret dex-config \
    -o jsonpath='{.data.config\.yaml}' | openssl base64 -d -A)
  if ! grep -Fxq "issuer: $issuer" <<< "$existing_config"; then
    printf 'Existing dex-config has a different issuer. Resolve it before rerunning.\n' >&2
    exit 1
  fi
  unset existing_config
  printf 'Dex and OAuth client Secrets already exist; reusing them.\n'
elif (( secrets_present != 0 )); then
  printf 'Only %s of 3 expected Secrets exist. Resolve the partial setup before rerunning.\n' "$secrets_present" >&2
  exit 1
else
  if [[ ${DEX_NONINTERACTIVE:-0} == 1 ]]; then
    user_email=${DEX_ADMIN_EMAIL:-}
    if [[ -z "$user_email" ]]; then
      printf 'Set DEX_ADMIN_EMAIL for noninteractive bootstrap.\n' >&2
      exit 1
    fi
  else
    read -r -p 'Dex login email (also the username): ' user_email
  fi
  if [[ ! "$user_email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
    printf 'Enter a valid email address.\n' >&2
    exit 1
  fi
  if [[ ${DEX_NONINTERACTIVE:-0} == 1 ]]; then
    umask 077
    credential_dir="$HOME/.config/hermetiq/dex/$domain_base"
    credential_file="$credential_dir/dex-admin-password"
    mkdir -p -- "$credential_dir"
    chmod 700 "$credential_dir"
    if [[ -L "$credential_file" ]]; then
      printf 'Refusing to use symlinked password file: %s\n' "$credential_file" >&2
      exit 1
    fi
    if [[ ! -e "$credential_file" ]]; then
      openssl rand -hex 32 > "$credential_file"
    fi
    chmod 600 "$credential_file"
    user_password=$(<"$credential_file")
    printf 'Local Dex password saved at %s\n' "$credential_file"
  else
    read -r -s -p 'Password for that user: ' user_password
    printf '\n'
    read -r -s -p 'Confirm password: ' confirmation
    printf '\n'
    if [[ ${#user_password} -lt 16 || "$user_password" != "$confirmation" ]]; then
      printf 'Passwords must match and have at least 16 characters.\n' >&2
      exit 1
    fi
    unset confirmation
  fi

  umask 077
  temp_dir=$(mktemp -d)
  trap 'rm -rf -- "$temp_dir"' EXIT
  password_hash=$(printf '%s\n' "$user_password" | htpasswd -niB -C 12 dex | cut -d : -f 2)
  unset user_password
  user_id=$(uuidgen | tr '[:upper:]' '[:lower:]')
  # Notice: the newline in secrets is stripped for a reason:
  # shells (i.e. bash) will strip the newline character silently,
  # which becomes a non-obvious source of authentication errors
  # when their values are used to login via curl etc.
  openssl rand -hex 32 | tr -d '\n' > "$temp_dir/client-secret"
  openssl rand -base64 32 | tr -d '\n' | tr '+/' '-_' > "$temp_dir/cookie-secret"
  printf 'hermetiq-web' > "$temp_dir/client-id"

  cat > "$temp_dir/config.yaml" <<EOF
issuer: $issuer
storage:
  type: kubernetes
  config:
    inCluster: true
oauth2:
  skipApprovalScreen: true
  passwordConnector: local
enablePasswordDB: true
signer:
  type: local
  config:
    keysRotationPeriod: "8760h"
staticClients:
  - id: hermetiq-web
    name: Hermetiq test installation
    secretEnv: DEX_CLIENT_SECRET
    redirectURIs:
      - https://dashboard.$domain_base/oauth2/callback
      - https://browser.$domain_base/oauth2/callback
      - https://grafana.$domain_base/oauth2/callback
  - id: bazel-cli
    name: Bazel CLI
    public: true
staticPasswords:
  - email: "$user_email"
    username: "$user_email"
    userID: "$user_id"
    hash: "$password_hash"
    groups:
      - hermetiq-admin
EOF
  unset password_hash

  kubectl "${kubectl_context[@]}" -n "$namespace" create secret generic dex-config \
    --from-file=config.yaml="$temp_dir/config.yaml"
  kubectl "${kubectl_context[@]}" -n "$namespace" create secret generic dex-client \
    --from-file=DEX_CLIENT_SECRET="$temp_dir/client-secret"
  kubectl "${kubectl_context[@]}" -n "$namespace" create secret generic oauth2-proxy-client \
    --from-file=OAUTH2_PROXY_CLIENT_ID="$temp_dir/client-id" \
    --from-file=OAUTH2_PROXY_CLIENT_SECRET="$temp_dir/client-secret" \
    --from-file=OAUTH2_PROXY_COOKIE_SECRET="$temp_dir/cookie-secret"
  printf 'Dex login username: %s\n' "$user_email"
fi

helm repo add dex https://charts.dexidp.io --force-update
helm repo update dex
helm "${helm_context[@]}" upgrade --install dex dex/dex --version 0.25.2 \
  --namespace "$namespace" --values "$script_dir/dex-values.yaml" \
  --set-string "httpRoute.hostnames[0]=dex.$domain_base" \
  --set-string "httpRoute.parentRefs[0].name=$gateway_name" \
  --wait --timeout 10m

kubectl "${kubectl_context[@]}" -n "$namespace" rollout status deployment/dex --timeout=180s
kubectl "${kubectl_context[@]}" -n "$namespace" get httproute dex
printf 'Dex issuer: %s\n' "$issuer"
