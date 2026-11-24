{{/* Keep browser admission consistent across the dashboard, Grafana and the
     Buildbarn Browser, which consume the same oauth2-proxy ConfigMap. */}}
{{- define "hermetiq-core.oauth2ProxyGroupsClaim" -}}
{{- default (default "groups" .Values.api.jwt.groupsClaim) .Values.dashboard.oauth2Proxy.oidcGroupsClaim -}}
{{- end -}}

{{- define "hermetiq-core.validateOauth2Admission" -}}
{{- $oauth := .Values.dashboard.oauth2Proxy -}}
{{- if or $oauth.enabled (and .Values.gateway.routes.grafanaEnabled (eq (include "hermetiq-core.grafanaOauth2ProxyEnabled" .) "true")) -}}
  {{- if not $oauth.emailDomains -}}
    {{- fail "dashboard.oauth2Proxy.emailDomains must explicitly list permitted email domains; use [\"*\"] only with nonempty allowedGroups" -}}
  {{- end -}}
  {{- range $oauth.emailDomains -}}
    {{- if not (regexMatch "^[^[:space:],]+$" .) -}}
      {{- fail "dashboard.oauth2Proxy.emailDomains entries must be nonempty domains without whitespace or commas" -}}
    {{- end -}}
  {{- end -}}
  {{- range $oauth.allowedGroups -}}
    {{- if or (not (trim .)) (ne (trim .) .) (contains "," .) (contains "\n" .) (contains "\r" .) -}}
      {{- fail "dashboard.oauth2Proxy.allowedGroups entries must be nonempty group names without surrounding whitespace, newlines or commas" -}}
    {{- end -}}
  {{- end -}}
  {{- if and (has "*" $oauth.emailDomains) (not $oauth.allowedGroups) -}}
    {{- fail "dashboard.oauth2Proxy.emailDomains=[\"*\"] requires nonempty dashboard.oauth2Proxy.allowedGroups; unrestricted browser admission is not supported" -}}
  {{- end -}}
  {{- range $workload, $env := dict "dashboard" (default dict $oauth.env) "grafana" (default dict $.Values.grafana.oauth2Proxy.env) -}}
    {{- range list "OAUTH2_PROXY_EMAIL_DOMAINS" "OAUTH2_PROXY_ALLOWED_GROUPS" "OAUTH2_PROXY_OIDC_GROUPS_CLAIM" -}}
      {{- if hasKey $env . -}}
        {{- fail (printf "%s.oauth2Proxy.env must not set %s; use shared dashboard.oauth2Proxy.emailDomains, allowedGroups and oidcGroupsClaim" $workload .) -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- end -}}
