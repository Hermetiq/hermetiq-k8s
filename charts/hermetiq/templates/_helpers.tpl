{{- define "hermetiq-core.namespace" -}}
{{- default .Release.Namespace .Values.namespaceOverride -}}
{{- end -}}

{{- define "hermetiq-core.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "hermetiq-core.labels" -}}
{{- $commonLabels := omit (default dict .Values.commonLabels) "helm.sh/chart" "app.kubernetes.io/name" "app.kubernetes.io/instance" "app.kubernetes.io/version" "app.kubernetes.io/managed-by" "app.kubernetes.io/part-of" "app.kubernetes.io/component" "hermetiq.com/stream-partition" -}}
{{- $standardLabels := default (dict) .Values.standardLabels -}}
helm.sh/chart: {{ include "hermetiq-core.chart" . }}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- if $standardLabels.appVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: hermetiq{{ if $commonLabels }}
{{ include "hermetiq-core.tplvalues.render" (dict "value" $commonLabels "context" .) }}{{ end }}
{{- end -}}

{{- define "hermetiq-core.componentLabel" -}}
app.kubernetes.io/component: {{ required "component is required" .component | quote }}
{{- end -}}

{{/* Stable identity labels for chart-managed Pods. Deliberately excludes
     helm.sh/chart and app.kubernetes.io/version so a chart-only release does
     not roll every workload. Legacy selector labels are rendered separately
     by each workload and cannot be overridden through podLabels. */}}
{{- define "hermetiq-core.podLabels" -}}
{{- $root := required "root is required" .root -}}
{{- $component := required "component is required" .component -}}
{{- $podLabels := omit (default dict $root.Values.podLabels) "app" "app-mode" "helm.sh/chart" "app.kubernetes.io/name" "app.kubernetes.io/instance" "app.kubernetes.io/version" "app.kubernetes.io/component" "app.kubernetes.io/part-of" "app.kubernetes.io/managed-by" "azure.workload.identity/use" "hermetiq.com/stream-partition" -}}
app.kubernetes.io/name: {{ $root.Chart.Name }}
app.kubernetes.io/instance: {{ $root.Release.Name }}
app.kubernetes.io/component: {{ $component | quote }}
app.kubernetes.io/managed-by: {{ $root.Release.Service }}
app.kubernetes.io/part-of: hermetiq{{ if $podLabels }}
{{ include "hermetiq-core.tplvalues.render" (dict "value" $podLabels "context" $root) }}{{ end }}
{{- end -}}

{{- define "hermetiq-core.preferredPodAntiAffinity" -}}
{{- $app := required "app is required" .app -}}
affinity:
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          labelSelector:
            matchLabels:
              app: {{ $app }}
          topologyKey: kubernetes.io/hostname
{{- end -}}

{{- define "hermetiq-core.tplvalues.render" -}}
{{- $value := .value -}}
{{- $context := .context -}}
{{- if kindIs "string" $value -}}
{{- tpl $value $context -}}
{{- else -}}
{{- tpl (toYaml $value) $context -}}
{{- end -}}
{{- end -}}

{{- define "hermetiq-core.commonAnnotations" -}}
{{- with .Values.commonAnnotations }}
{{- include "hermetiq-core.tplvalues.render" (dict "value" . "context" $) }}
{{- end -}}
{{- end -}}

{{- define "hermetiq-core.rewriteImageRepository" -}}
{{- $repo := .repository -}}
{{- $registry := trimSuffix "/" (default "" .registry) -}}
{{- if $registry -}}
{{- $parts := splitList "/" $repo -}}
{{- if gt (len $parts) 1 -}}
{{- printf "%s/%s" $registry (join "/" (rest $parts)) -}}
{{- else -}}
{{- printf "%s/%s" $registry $repo -}}
{{- end -}}
{{- else -}}
{{- $repo -}}
{{- end -}}
{{- end -}}

{{- define "hermetiq-core.image" -}}
{{- $root := required "root is required" .root -}}
{{- $global := default (dict) $root.Values.global -}}
{{- $repo := required (printf "%s.repository is required" .name) .repository -}}
{{- $tag := required (printf "%s.tag is required" .name) .tag -}}
{{- $repo = include "hermetiq-core.rewriteImageRepository" (dict "repository" $repo "registry" $global.imageRegistry) -}}
{{- $image := printf "%s:%s" $repo $tag -}}
{{- with .digest -}}
{{- printf "%s@%s" $image (trimPrefix "@" .) -}}
{{- else -}}
{{- $image -}}
{{- end -}}
{{- end -}}

{{- define "hermetiq-core.imagePullSecrets" -}}
{{- $global := default (dict) .Values.global -}}
{{- $secrets := list -}}
{{- range (default list $global.imagePullSecrets) -}}
{{- $secrets = append $secrets . -}}
{{- end -}}
{{- range (default list .Values.imagePullSecrets) -}}
{{- $secrets = append $secrets . -}}
{{- end -}}
{{- $seen := dict -}}
{{- $merged := list -}}
{{- range $secret := $secrets -}}
{{- $key := toJson $secret -}}
{{- if not (hasKey $seen $key) -}}
{{- $_ := set $seen $key true -}}
{{- $merged = append $merged $secret -}}
{{- end -}}
{{- end -}}
{{- if $merged }}
imagePullSecrets:
{{- toYaml $merged | nindent 2 }}
{{- end }}
{{- end -}}

{{- define "hermetiq-core.host" -}}
{{- $root := .root -}}
{{- $value := default "" .value -}}
{{- if $value -}}
{{- tpl $value $root -}}
{{- else -}}
{{- $base := required (printf "%s or hosts.domainBase is required" .name) $root.Values.hosts.domainBase -}}
{{- $base = tpl $base $root -}}
{{- printf "%s.%s" .subdomain $base -}}
{{- end -}}
{{- end -}}

{{- define "hermetiq-core.bepGrpcHost" -}}
{{- include "hermetiq-core.host" (dict "root" . "value" .Values.hosts.bepGrpc "subdomain" "bep" "name" "hosts.bepGrpc") -}}
{{- end -}}

{{- define "hermetiq-core.apiGrpcHost" -}}
{{- include "hermetiq-core.host" (dict "root" . "value" .Values.hosts.apiGrpc "subdomain" "api" "name" "hosts.apiGrpc") -}}
{{- end -}}

{{- define "hermetiq-core.apiHost" -}}
{{- include "hermetiq-core.host" (dict "root" . "value" .Values.hosts.api "subdomain" "api-web" "name" "hosts.api") -}}
{{- end -}}

{{- define "hermetiq-core.dashboardHost" -}}
{{- include "hermetiq-core.host" (dict "root" . "value" .Values.hosts.dashboard "subdomain" "dashboard" "name" "hosts.dashboard") -}}
{{- end -}}

{{- define "hermetiq-core.mcpHost" -}}
{{- include "hermetiq-core.host" (dict "root" . "value" .Values.hosts.mcp "subdomain" "mcp" "name" "hosts.mcp") -}}
{{- end -}}

{{- define "hermetiq-core.bbcalGrpcHost" -}}
{{- include "hermetiq-core.host" (dict "root" . "value" .Values.hosts.bbcalGrpc "subdomain" "bbcal" "name" "hosts.bbcalGrpc") -}}
{{- end -}}

{{- define "hermetiq-core.dashboardRemoteCacheUrl" -}}
{{- if .Values.dashboard.remoteCacheUrl -}}
{{- tpl .Values.dashboard.remoteCacheUrl . -}}
{{- else if .Values.gateway.routes.bbcalGrpcEnabled -}}
{{- printf "grpcs://%s" (include "hermetiq-core.bbcalGrpcHost" .) -}}
{{- else if .Values.hosts.domainBase -}}
{{- printf "grpcs://bb.%s" (tpl .Values.hosts.domainBase .) -}}
{{- end -}}
{{- end -}}

{{- define "hermetiq-core.grafanaHost" -}}
{{- include "hermetiq-core.host" (dict "root" . "value" .Values.hosts.grafana "subdomain" "grafana" "name" "hosts.grafana") -}}
{{- end -}}

{{- define "hermetiq-core.dashboardUrl" -}}
{{- printf "https://%s" (include "hermetiq-core.dashboardHost" .) -}}
{{- end -}}

{{- define "hermetiq-core.mcpResourceUrl" -}}
{{- default (printf "https://%s" (include "hermetiq-core.mcpHost" .)) .Values.api.mcpResourceUrl -}}
{{- end -}}

{{/* MCP authorization server advertised in the protected-resource metadata.
     Explicit api.mcpAuthorizationServer wins; otherwise derived from the OIDC
     issuer with any trailing slash stripped (the MCP server appends
     /.well-known/oauth-authorization-server, so a trailing slash would produce
     a double slash). Renders empty when no issuer is configured. */}}
{{- define "hermetiq-core.mcpAuthorizationServer" -}}
{{- if .Values.api.mcpAuthorizationServer -}}
{{- .Values.api.mcpAuthorizationServer -}}
{{- else -}}
{{- trimSuffix "/" (include "hermetiq-core.apiJwtIssuer" .) -}}
{{- end -}}
{{- end -}}

{{- define "hermetiq-core.gatewayNamespace" -}}
{{- default (include "hermetiq-core.namespace" .) .Values.gateway.namespace -}}
{{- end -}}

{{- define "hermetiq-core.parentRefs" -}}
- name: {{ required "gateway.name is required" .Values.gateway.name | quote }}
{{- if ne (include "hermetiq-core.gatewayNamespace" .) (include "hermetiq-core.namespace" .) }}
  namespace: {{ include "hermetiq-core.gatewayNamespace" . | quote }}
{{- end }}
{{- end -}}

{{- define "hermetiq-core.routingProvider" -}}
{{- if not .Values.routing.enabled -}}
none
{{- else if eq .Values.routing.provider "none" -}}
none
{{- else if .Values.routing.provider -}}
{{- .Values.routing.provider -}}
{{- else if .Values.contour.enabled -}}
contour
{{- else if .Values.gateway.enabled -}}
gateway
{{- else -}}
ingress
{{- end -}}
{{- end -}}

{{- define "hermetiq-core.routeTlsSecretName" -}}
{{- $root := .root -}}
{{- $specific := default "" .secretName -}}
{{- if $root.Values.tls.secretName -}}
{{- $root.Values.tls.secretName -}}
{{- else if $root.Values.tls.certificate.enabled -}}
{{- $root.Values.tls.certificate.name -}}
{{- else -}}
{{- default .defaultName $specific -}}
{{- end -}}
{{- end -}}

{{- define "hermetiq-core.renderPerRouteCertificates" -}}
{{- $provider := include "hermetiq-core.routingProvider" . -}}
{{- if and (not .Values.tls.secretName) (not .Values.tls.certificate.enabled) -}}
  {{- if and (eq $provider "contour") .Values.contour.certManager.enabled -}}
true
  {{- else if and (eq $provider "ingress") .Values.ingress.certManager.enabled -}}
true
  {{- end -}}
{{- end -}}
{{- end -}}

{{- define "hermetiq-core.serviceAccountName" -}}
{{- default "bep-nats" .Values.serviceAccount.name -}}
{{- end -}}

{{/* Top-level OIDC issuer URL preserved as-is (trailing slash matters for
     OIDC issuer comparison — Auth0 JWTs include it). */}}
{{- define "hermetiq-core.oidcIssuerUrl" -}}
{{- default "" .Values.oidc.issuerUrl -}}
{{- end -}}

{{/* JWKS URL: explicit `oidc.jwksUrl` first, else derived from issuer
     (trailing slash trimmed before joining the well-known suffix). */}}
{{- define "hermetiq-core.oidcJwksUrl" -}}
{{- if .Values.oidc.jwksUrl -}}
{{- .Values.oidc.jwksUrl -}}
{{- else -}}
{{- $issuer := trimSuffix "/" (include "hermetiq-core.oidcIssuerUrl" .) -}}
{{- if $issuer -}}
{{- printf "%s/.well-known/jwks.json" $issuer -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/* api.jwt.issuer with fallback to oidc.issuerUrl. */}}
{{- define "hermetiq-core.apiJwtIssuer" -}}
{{- default (include "hermetiq-core.oidcIssuerUrl" .) .Values.api.jwt.issuer -}}
{{- end -}}

{{/* api.jwt.jwksUrl with fallback to derived OIDC JWKS URL. */}}
{{- define "hermetiq-core.apiJwtJwksUrl" -}}
{{- default (include "hermetiq-core.oidcJwksUrl" .) .Values.api.jwt.jwksUrl -}}
{{- end -}}

{{/* publisher.jwks.issuer with fallback to oidc.issuerUrl. */}}
{{- define "hermetiq-core.publisherJwksIssuer" -}}
{{- default (include "hermetiq-core.oidcIssuerUrl" .) .Values.publisher.jwks.issuer -}}
{{- end -}}

{{/* publisher.jwks.url with fallback to derived OIDC JWKS URL. */}}
{{- define "hermetiq-core.publisherJwksUrl" -}}
{{- default (include "hermetiq-core.oidcJwksUrl" .) .Values.publisher.jwks.url -}}
{{- end -}}

{{/* Identity provider for every bep-nats core that serves gRPC, rendered as
     GRPC_AUTH_USER_PROVIDER. The core validates it at startup and refuses to
     run without it, so this is always emitted rather than gated on
     api.jwt.enabled / publisher.jwks.enabled — those now only decide whether
     the chart supplies the JWKS settings the provider needs. */}}
{{- define "hermetiq-core.grpcAuthUserProvider" -}}
{{- required "app.grpcAuthUserProvider is required (\"jwks\" for on-prem, \"stytch\" for Hermetiq SaaS)" .Values.app.grpcAuthUserProvider -}}
{{- end -}}

{{/* Resolve one scalar entry from an extra-env map exactly as extraEnv does.
     Validation uses this to recognize only custom GRPC_AUTH_* values that the
     chart can prove it will render; absent, empty, and tpl-expanded-to-empty
     entries do not satisfy a required JWKS setting. */}}
{{- define "hermetiq-core.customEnvValue" -}}
{{- $env := default (dict) .env -}}
{{- if hasKey $env .name -}}
{{- tpl (toString (get $env .name)) .root | trim -}}
{{- end -}}
{{- end -}}

{{/* Whether the api core's gRPC audience comes from the dashboard
     oauth2-proxy client ID rather than an explicit api.jwt.audience. Mirrors
     the grpc-auth-proxy sidecar's JWT_AUDIENCE fallback in
     deployment-api.yaml, which is deliberately left untouched — the sidecar
     binary still reads JWT_*. The client ID lives in a Secret, so the core
     takes it as a separate env var and interpolates it into
     GRPC_AUTH_AUDIENCE with $(...) expansion. */}}
{{- define "hermetiq-core.apiJwtAudienceFromOauth2Secret" -}}
{{- if and .Values.api.jwt.enabled .Values.dashboard.oauth2Proxy.enabled (not .Values.api.jwt.audience) -}}true{{- end -}}
{{- end -}}

{{/* Whether bep-nats-pub should be fronted by grpc-auth-proxy. */}}
{{- define "hermetiq-core.publisherAuthProxyEnabled" -}}
{{- if and (not .Values.publisher.jwks.enabled) (trim .Values.publisher.authProxy.staticForwardedUser) -}}true{{- end -}}
{{- end -}}

{{/* dashboard.oauth2Proxy.oidcIssuerUrl with fallback. Required when oauth2Proxy is enabled. */}}
{{- define "hermetiq-core.dashboardOidcIssuerUrl" -}}
{{- default (include "hermetiq-core.oidcIssuerUrl" .) .Values.dashboard.oauth2Proxy.oidcIssuerUrl -}}
{{- end -}}

{{- define "hermetiq-core.oauth2ProxyConfigData" -}}
OAUTH2_PROXY_AUTH_LOGGING: "true"
OAUTH2_PROXY_COOKIE_HTTPONLY: "true"
OAUTH2_PROXY_COOKIE_SAMESITE: lax
OAUTH2_PROXY_COOKIE_SECURE: {{ .Values.dashboard.oauth2Proxy.cookieSecure | quote }}
{{- if .Values.dashboard.oauth2Proxy.cookieExpire }}
OAUTH2_PROXY_COOKIE_EXPIRE: {{ .Values.dashboard.oauth2Proxy.cookieExpire | quote }}
{{- end }}
{{- if .Values.dashboard.oauth2Proxy.cookieRefresh }}
OAUTH2_PROXY_COOKIE_REFRESH: {{ .Values.dashboard.oauth2Proxy.cookieRefresh | quote }}
{{- end }}
OAUTH2_PROXY_EMAIL_DOMAINS: "*"
OAUTH2_PROXY_HTTP_ADDRESS: 0.0.0.0:8888
OAUTH2_PROXY_INSECURE_OIDC_ALLOW_UNVERIFIED_EMAIL: {{ .Values.dashboard.oauth2Proxy.insecureOidcAllowUnverifiedEmail | quote }}
OAUTH2_PROXY_INSECURE_OIDC_SKIP_ISSUER_VERIFICATION: {{ .Values.dashboard.oauth2Proxy.insecureOidcSkipIssuerVerification | quote }}
OAUTH2_PROXY_OIDC_GROUPS_CLAIM: {{ .Values.dashboard.oauth2Proxy.oidcGroupsClaim | quote }}
OAUTH2_PROXY_OIDC_ISSUER_URL: {{ required "dashboard.oauth2Proxy.oidcIssuerUrl or oidc.issuerUrl is required when oauth2Proxy is enabled" (include "hermetiq-core.dashboardOidcIssuerUrl" .) | quote }}
OAUTH2_PROXY_PASS_ACCESS_TOKEN: "true"
OAUTH2_PROXY_PASS_AUTHORIZATION_HEADER: "true"
OAUTH2_PROXY_PASS_USER_HEADERS: {{ .Values.dashboard.oauth2Proxy.passUserHeaders | quote }}
OAUTH2_PROXY_PROVIDER: {{ .Values.dashboard.oauth2Proxy.provider | quote }}
OAUTH2_PROXY_REAL_CLIENT_IP_HEADER: X-Forwarded-For
OAUTH2_PROXY_REQUEST_LOGGING: "true"
OAUTH2_PROXY_REVERSE_PROXY: "true"
OAUTH2_PROXY_SCOPE: {{ .Values.dashboard.oauth2Proxy.scope | quote }}
OAUTH2_PROXY_SET_XAUTHREQUEST: {{ .Values.dashboard.oauth2Proxy.setXAuthRequest | quote }}
OAUTH2_PROXY_SESSION_COOKIE_MINIMAL: {{ .Values.dashboard.oauth2Proxy.sessionCookieMinimal | quote }}
OAUTH2_PROXY_SHOW_DEBUG_ON_ERROR: {{ .Values.dashboard.oauth2Proxy.showDebugOnError | quote }}
OAUTH2_PROXY_SILENCE_PING_LOGGING: "true"
OAUTH2_PROXY_SKIP_AUTH_PREFLIGHT: {{ .Values.dashboard.oauth2Proxy.skipAuthPreflight | quote }}
{{- if .Values.dashboard.oauth2Proxy.skipAuthRoutes }}
OAUTH2_PROXY_SKIP_AUTH_ROUTES: {{ .Values.dashboard.oauth2Proxy.skipAuthRoutes | quote }}
{{- else }}
OAUTH2_PROXY_SKIP_AUTH_ROUTES: "GET=^/login$,GET=^/favicon\\.ico$,GET=^/logo192\\.png$,GET=^/robots\\.txt$,GET=^/env-config\\.js$,GET=^/quickstart-config/quickstart-config\\.json$,GET=^/static/.*$"
{{- end }}
OAUTH2_PROXY_SKIP_JWT_BEARER_TOKENS: {{ .Values.dashboard.oauth2Proxy.skipJwtBearerTokens | quote }}
OAUTH2_PROXY_SKIP_OIDC_DISCOVERY: {{ .Values.dashboard.oauth2Proxy.skipOidcDiscovery | quote }}
OAUTH2_PROXY_SKIP_PROVIDER_BUTTON: {{ .Values.dashboard.oauth2Proxy.skipProviderButton | quote }}
OAUTH2_PROXY_SSL_INSECURE_SKIP_VERIFY: {{ .Values.dashboard.oauth2Proxy.sslInsecureSkipVerify | quote }}
OAUTH2_PROXY_STANDARD_LOGGING: "true"
{{- if .Values.dashboard.oauth2Proxy.cookieDomains }}
OAUTH2_PROXY_COOKIE_DOMAINS: {{ join "," .Values.dashboard.oauth2Proxy.cookieDomains | quote }}
{{- end }}
{{- $whitelistDomains := default (list) .Values.dashboard.oauth2Proxy.whitelistDomains -}}
{{- if .Values.hosts.domainBase -}}
{{- $whitelistDomains = prepend $whitelistDomains (printf ".%s" .Values.hosts.domainBase) -}}
{{- end }}
{{- if $whitelistDomains }}
OAUTH2_PROXY_WHITELIST_DOMAINS: {{ join "," (uniq $whitelistDomains) | quote }}
{{- end }}
{{- if .Values.dashboard.oauth2Proxy.backendLogoutUrl }}
OAUTH2_PROXY_BACKEND_LOGOUT_URL: {{ .Values.dashboard.oauth2Proxy.backendLogoutUrl | quote }}
{{- end }}
{{- if .Values.dashboard.oauth2Proxy.validateUrl }}
OAUTH2_PROXY_VALIDATE_URL: {{ .Values.dashboard.oauth2Proxy.validateUrl | quote }}
{{- end }}
{{- end -}}

{{- define "hermetiq-core.oauth2ProxyConfigChecksum" -}}
{{- include "hermetiq-core.oauth2ProxyConfigData" . | sha256sum -}}
{{- end -}}

{{- define "hermetiq-core.oauth2ProxySecretData" -}}
OAUTH2_PROXY_CLIENT_ID: {{ required "dashboard.oauth2Proxy.client.clientId or existingSecret is required when oauth2Proxy is enabled" .Values.dashboard.oauth2Proxy.client.clientId | quote }}
OAUTH2_PROXY_CLIENT_SECRET: {{ required "dashboard.oauth2Proxy.client.clientSecret or existingSecret is required when oauth2Proxy is enabled" .Values.dashboard.oauth2Proxy.client.clientSecret | quote }}
OAUTH2_PROXY_COOKIE_SECRET: {{ required "dashboard.oauth2Proxy.client.cookieSecret or existingSecret is required when oauth2Proxy is enabled" .Values.dashboard.oauth2Proxy.client.cookieSecret | quote }}
{{- end -}}

{{- define "hermetiq-core.oauth2ProxySecretChecksum" -}}
{{- include "hermetiq-core.oauth2ProxySecretData" . | sha256sum -}}
{{- end -}}

{{- define "hermetiq-core.postgresSecretName" -}}
{{- default "postgres" .Values.postgres.password.existingSecret -}}
{{- end -}}

{{- define "hermetiq-core.redisSecretName" -}}
{{- default "dragonfly-auth" .Values.redis.password.existingSecret -}}
{{- end -}}

{{- define "hermetiq-core.oauth2ProxySecretName" -}}
{{- default "oauth2-proxy-client" .Values.dashboard.oauth2Proxy.client.existingSecret -}}
{{- end -}}

{{- define "hermetiq-core.grafanaOauth2ProxyName" -}}
grafana-oauth2-proxy
{{- end -}}

{{/* Treat only boolean true or string "true" as enabling the standalone
     Grafana oauth2-proxy. This keeps --set-string enabled=false from being
     truthy in Go templates. */}}
{{- define "hermetiq-core.grafanaOauth2ProxyEnabled" -}}
{{- if eq (lower (toString .Values.grafana.oauth2Proxy.enabled)) "true" -}}true{{- end -}}
{{- end -}}

{{/* Service the Grafana route forwards to. Swaps to the standalone
     oauth2-proxy when grafana.oauth2Proxy.enabled is true. */}}
{{- define "hermetiq-core.grafanaUpstreamService" -}}
{{- if eq (include "hermetiq-core.grafanaOauth2ProxyEnabled" .) "true" -}}
{{ include "hermetiq-core.grafanaOauth2ProxyName" . }}
{{- else -}}
{{ .Values.gateway.routes.grafanaService }}
{{- end -}}
{{- end -}}

{{- define "hermetiq-core.grafanaUpstreamServicePort" -}}
{{- if eq (include "hermetiq-core.grafanaOauth2ProxyEnabled" .) "true" -}}
80
{{- else -}}
{{ .Values.gateway.routes.grafanaServicePort }}
{{- end -}}
{{- end -}}

{{- define "hermetiq-core.pubJwksSecretName" -}}
{{- default "bep-pub-jwks" .Values.publisher.jwks.existingSecret -}}
{{- end -}}

{{- define "hermetiq-core.slackSecretName" -}}
{{- default "slack-chat-bot" .Values.slack.botToken.existingSecret -}}
{{- end -}}

{{- define "hermetiq-core.licenseSecretName" -}}
{{- default "hermetiq-license" .Values.license.key.existingSecret -}}
{{- end -}}

{{/* Secret the app itself writes license state into (auto-issued trial key,
     signed validation cache). Read via the K8s API, never mounted; the name
     is fixed because the license-state Role scopes its write verbs to it. */}}
{{- define "hermetiq-core.licenseStateSecretName" -}}hermetiq-license-state{{- end -}}

{{/* Whether a license key Secret is configured (inline value or a
     customer-managed Secret). Informational only (NOTES.txt): the
     /config/license volume is always mounted with optional: true. */}}
{{- define "hermetiq-core.licenseKeySecretEnabled" -}}
{{- if or .Values.license.key.value .Values.license.key.existingSecret -}}true{{- end -}}
{{- end -}}

{{- define "hermetiq-core.podScheduling" -}}
{{- $root := .root -}}
{{- $workload := default (dict) .workload -}}
{{- $global := default (dict) $root.Values.k8sNodeScheduling -}}
{{- $nodeSelector := default (dict) $global.nodeSelector -}}
{{- if and (hasKey $workload "nodeSelector") (ne $workload.nodeSelector nil) -}}
{{- $nodeSelector = $workload.nodeSelector -}}
{{- end -}}
{{- with $nodeSelector }}
nodeSelector:
{{- toYaml . | nindent 2 }}
{{- end }}
{{- $tolerations := default (list) $global.tolerations -}}
{{- if and (hasKey $workload "tolerations") (ne $workload.tolerations nil) -}}
{{- $tolerations = $workload.tolerations -}}
{{- end -}}
{{- with $tolerations }}
tolerations:
{{- toYaml . | nindent 2 }}
{{- end }}
{{- end -}}

{{- define "hermetiq-core.automountServiceAccountToken" -}}
{{- $workload := default (dict) . -}}
{{- if and (hasKey $workload "automountServiceAccountToken") (ne $workload.automountServiceAccountToken nil) }}
automountServiceAccountToken: {{ $workload.automountServiceAccountToken }}
{{- end }}
{{- end -}}

{{- define "hermetiq-core.tcpProbe" -}}
tcpSocket:
  port: {{ .port }}
{{- toYaml .settings | nindent 0 }}
{{- end -}}

{{- define "hermetiq-core.podSecurityContext" -}}
runAsNonRoot: {{ .Values.security.pod.runAsNonRoot }}
runAsUser: {{ .Values.security.pod.runAsUser }}
runAsGroup: {{ .Values.security.pod.runAsGroup }}
fsGroup: {{ .Values.security.pod.fsGroup }}
fsGroupChangePolicy: {{ .Values.security.pod.fsGroupChangePolicy }}
seccompProfile:
  type: {{ .Values.security.pod.seccompProfile.type }}
{{- end -}}

{{- define "hermetiq-core.containerSecurityContext" -}}
allowPrivilegeEscalation: {{ .Values.security.container.allowPrivilegeEscalation }}
readOnlyRootFilesystem: {{ .Values.security.container.readOnlyRootFilesystem }}
runAsNonRoot: {{ .Values.security.pod.runAsNonRoot }}
runAsUser: {{ .Values.security.pod.runAsUser }}
runAsGroup: {{ .Values.security.pod.runAsGroup }}
{{- if .Values.security.container.dropCapabilities }}
capabilities:
  drop:
{{- range .Values.security.container.dropCapabilities }}
    - {{ . | quote }}
{{- end }}
{{- end }}
{{- end -}}

{{- define "hermetiq-core.writableContainerSecurityContext" -}}
allowPrivilegeEscalation: {{ .Values.security.container.allowPrivilegeEscalation }}
readOnlyRootFilesystem: false
runAsNonRoot: {{ .Values.security.pod.runAsNonRoot }}
runAsUser: {{ .Values.security.pod.runAsUser }}
runAsGroup: {{ .Values.security.pod.runAsGroup }}
{{- if .Values.security.container.dropCapabilities }}
capabilities:
  drop:
{{- range .Values.security.container.dropCapabilities }}
    - {{ . | quote }}
{{- end }}
{{- end }}
{{- end -}}

{{- define "hermetiq-core.dashboardContainerSecurityContext" -}}
allowPrivilegeEscalation: {{ .Values.security.container.allowPrivilegeEscalation }}
readOnlyRootFilesystem: {{ .Values.dashboard.security.readOnlyRootFilesystem }}
runAsNonRoot: {{ .Values.dashboard.security.runAsNonRoot }}
runAsUser: {{ .Values.dashboard.security.runAsUser }}
runAsGroup: {{ .Values.dashboard.security.runAsGroup }}
{{- if .Values.dashboard.security.dropCapabilities }}
capabilities:
  drop:
{{- range .Values.dashboard.security.dropCapabilities }}
    - {{ . | quote }}
{{- end }}
{{- end }}
{{- end -}}

{{- define "hermetiq-core.workloadIdentityLabels" -}}
{{- if .Values.azureWorkloadIdentity.enabled }}
azure.workload.identity/use: "true"
{{- end }}
{{- end -}}

{{- define "hermetiq-core.extraEnv" -}}
{{- $root := .root -}}
{{- range $key, $value := .env -}}
- name: {{ $key }}
  value: {{ tpl (toString $value) $root | quote }}
{{ end -}}
{{- end -}}

{{- define "hermetiq-core.sharedEnvName" -}}bep-nats-shared-env{{- end -}}

{{/*
Contents of the shared env ConfigMap. Defined here rather than inline in
configmaps.yaml so sharedEnvChecksum hashes exactly what is rendered — every
consumer of this ConfigMap reads it through envFrom, which the kubelet does not
re-read after container start, so a values-only change has to roll the pods.
*/}}
{{- define "hermetiq-core.sharedEnvData" -}}
RAW_BEP_EXPORT_ENABLED: {{ ternary "true" "false" .Values.app.rawBepExportEnabled | quote }}
NORMALIZE_REPO_URLS: {{ ternary "true" "false" .Values.app.normalizeRepoUrls | quote }}
APP_ENVIRONMENT: {{ .Values.app.environment | quote }}
INVOCATION_START_EVENT: {{ .Values.app.invocationStartEvent | quote }}
TEMPORAL_ENABLED: "false"
PGSSLMODE: {{ .Values.postgres.sslMode | quote }}
NATS_URL: {{ required "nats.url is required" .Values.nats.url | quote }}
STREAM_PARTITION_COUNT: {{ .Values.app.streamPartitionCount | quote }}
REDIS_HOST: {{ required "redis.host is required" .Values.redis.host | quote }}
GH_ENABLED: "false"
OTEL_EXPORTER_OTLP_ENDPOINT: {{ required "otel.endpoint is required" .Values.otel.endpoint | quote }}
OTEL_EXPORTER_OTLP_PROTOCOL: {{ .Values.otel.protocol | quote }}
OTEL_SERVICE_NAME: {{ required "otel.serviceName is required" .Values.otel.serviceName | quote }}
OTEL_INTERVAL: {{ .Values.app.otelInterval | quote }}
{{- end -}}

{{- define "hermetiq-core.sharedEnvChecksum" -}}
{{- include "hermetiq-core.sharedEnvData" . | sha256sum -}}
{{- end -}}
{{- define "hermetiq-core.natsStreamConfigName" -}}
{{- default "bep-nats-stream-config" .Values.nats.streamConfig.existingConfigMap -}}
{{- end -}}
{{- define "hermetiq-core.cacheTtlConfigName" -}}
{{- default "bep-cache-ttl-config" .Values.cacheTtl.existingConfigMap -}}
{{- end -}}
{{- define "hermetiq-core.promqlConfigName" -}}
{{- default "bep-promql-config" .Values.promqlQueries.existingConfigMap -}}
{{- end -}}
{{- define "hermetiq-core.dashboardQuickstartConfigName" -}}web-ui-quickstart-config{{- end -}}

{{- define "hermetiq-core.natsStreamConfigChecksum" -}}
{{- if .Values.nats.streamConfig.existingConfigMap -}}
{{- dict "configMapKey" .Values.nats.streamConfig.configMapKey "existingConfigMap" .Values.nats.streamConfig.existingConfigMap "rolloutChecksum" .Values.nats.streamConfig.rolloutChecksum | toJson | sha256sum -}}
{{- else -}}
{{- dict "configMapKey" .Values.nats.streamConfig.configMapKey "data" (.Files.Get "files/config/nats_streams.json") | toJson | sha256sum -}}
{{- end -}}
{{- end -}}

{{- define "hermetiq-core.cacheTtlConfigChecksum" -}}
{{- if .Values.cacheTtl.existingConfigMap -}}
{{- dict "configMapKey" .Values.cacheTtl.configMapKey "existingConfigMap" .Values.cacheTtl.existingConfigMap "rolloutChecksum" .Values.cacheTtl.rolloutChecksum | toJson | sha256sum -}}
{{- else -}}
{{- dict "configMapKey" .Values.cacheTtl.configMapKey "data" (.Files.Get "files/config/cache_ttl.json") | toJson | sha256sum -}}
{{- end -}}
{{- end -}}

{{- define "hermetiq-core.promqlConfigChecksum" -}}
{{- if .Values.promqlQueries.existingConfigMap -}}
{{- dict "configMapKey" .Values.promqlQueries.configMapKey "existingConfigMap" .Values.promqlQueries.existingConfigMap "rolloutChecksum" .Values.promqlQueries.rolloutChecksum | toJson | sha256sum -}}
{{- else -}}
{{- dict "configMapKey" .Values.promqlQueries.configMapKey "data" (.Files.Get "files/config/promql.json") | toJson | sha256sum -}}
{{- end -}}
{{- end -}}
{{- define "hermetiq-core.apiName" -}}grpc-api{{- end -}}
{{- define "hermetiq-core.publisherName" -}}bep-nats-pub{{- end -}}
{{- define "hermetiq-core.dashboardName" -}}web-ui{{- end -}}
{{- define "hermetiq-core.contourCorsOrigin" -}}
{{- if .Values.contour.cors.allowOrigins -}}
{{- join "," .Values.contour.cors.allowOrigins -}}
{{- else -}}
{{- include "hermetiq-core.dashboardUrl" . -}}
{{- end -}}
{{- end -}}

{{- define "hermetiq-core.nginxCorsOrigin" -}}
{{- if .Values.ingress.cors.allowOrigins -}}
{{- join "," .Values.ingress.cors.allowOrigins -}}
{{- else -}}
{{- include "hermetiq-core.dashboardUrl" . -}}
{{- end -}}
{{- end -}}

{{- define "hermetiq-core.webCorsOrigins" -}}
{{- $provider := include "hermetiq-core.routingProvider" . -}}
{{- if and (has $provider (list "gateway" "gateway-httproute-only")) .Values.gateway.cors.allowOrigins -}}
{{- join "," .Values.gateway.cors.allowOrigins -}}
{{- else if and (eq $provider "contour") .Values.contour.cors.allowOrigins -}}
{{- join "," .Values.contour.cors.allowOrigins -}}
{{- else if and (eq $provider "ingress") .Values.ingress.cors.allowOrigins -}}
{{- join "," .Values.ingress.cors.allowOrigins -}}
{{- else -}}
{{- include "hermetiq-core.dashboardUrl" . -}}
{{- end -}}
{{- end -}}

{{- define "hermetiq-core.apiCorsAllowedOrigins" -}}
{{- if .Values.api.corsAllowedOrigins -}}
{{- .Values.api.corsAllowedOrigins -}}
{{- else if .Values.api.authProxy.corsAllowedOrigins -}}
{{- .Values.api.authProxy.corsAllowedOrigins -}}
{{- else -}}
{{- include "hermetiq-core.webCorsOrigins" . -}}
{{- end -}}
{{- end -}}

{{- define "hermetiq-core.authProxyCorsAllowedOrigins" -}}
{{- if .Values.api.authProxy.corsAllowedOrigins -}}
{{- .Values.api.authProxy.corsAllowedOrigins -}}
{{- else if eq (include "hermetiq-core.routingProvider" .) "gateway-httproute-only" -}}
{{- include "hermetiq-core.apiCorsAllowedOrigins" . -}}
{{- end -}}
{{- end -}}

{{- define "hermetiq-core.adminEmails" -}}
{{- $emails := default (list) .Values.app.adminEmails -}}
{{- if kindIs "slice" $emails -}}
{{- join "," $emails -}}
{{- else -}}
{{- $emails -}}
{{- end -}}
{{- end -}}

{{- define "hermetiq-core.nginxCorsAnnotations" -}}
nginx.ingress.kubernetes.io/enable-cors: "true"
nginx.ingress.kubernetes.io/cors-allow-origin: {{ include "hermetiq-core.nginxCorsOrigin" . | quote }}
nginx.ingress.kubernetes.io/cors-allow-headers: {{ join "," .Values.ingress.cors.allowHeaders | quote }}
nginx.ingress.kubernetes.io/cors-expose-headers: {{ join "," .Values.ingress.cors.exposeHeaders | quote }}
nginx.ingress.kubernetes.io/cors-allow-credentials: {{ .Values.ingress.cors.allowCredentials | quote }}
nginx.ingress.kubernetes.io/cors-max-age: {{ .Values.ingress.cors.maxAgeSeconds | quote }}
nginx.ingress.kubernetes.io/cors-allow-methods: {{ join "," .Values.ingress.cors.allowMethods | quote }}
{{- end -}}

{{- define "hermetiq-core.nginxMcpCorsAnnotations" -}}
nginx.ingress.kubernetes.io/enable-cors: "true"
nginx.ingress.kubernetes.io/cors-allow-origin: {{ join "," .Values.ingress.cors.mcpAllowOrigins | quote }}
nginx.ingress.kubernetes.io/cors-allow-headers: {{ printf "mcp-protocol-version,%s" (join "," .Values.ingress.cors.allowHeaders) | quote }}
nginx.ingress.kubernetes.io/cors-expose-headers: {{ printf "%s,mcp-protocol-version" (join "," .Values.ingress.cors.exposeHeaders) | quote }}
nginx.ingress.kubernetes.io/cors-allow-credentials: {{ .Values.ingress.cors.allowCredentials | quote }}
nginx.ingress.kubernetes.io/cors-max-age: {{ .Values.ingress.cors.maxAgeSeconds | quote }}
nginx.ingress.kubernetes.io/cors-allow-methods: {{ join "," .Values.ingress.cors.allowMethods | quote }}
{{- end -}}

{{/* Envoy Gateway BackendTrafficPolicy `timeout:` block for one gRPC route.
     Args: dict "root" $ "route" <key under gateway.timeouts>.

     Renders nothing when gateway.timeouts.enabled is false or the route sets
     none of the three fields, so callers can use `with` to decide whether the
     block exists at all. Each field is emitted only when non-empty — an unset
     field leaves Envoy's own default in place, which is not the same as "0s"
     (0s means *disabled*, not *immediate*). */}}
{{- define "hermetiq-core.routeTimeout" -}}
{{- $timeouts := .root.Values.gateway.timeouts | default dict -}}
{{- if $timeouts.enabled -}}
{{- $route := index $timeouts .route | default dict -}}
{{- if or $route.requestTimeout $route.maxStreamDuration $route.connectionIdleTimeout -}}
timeout:
  http:
    {{- with $route.requestTimeout }}
    requestTimeout: {{ . | quote }}
    {{- end }}
    {{- with $route.maxStreamDuration }}
    maxStreamDuration: {{ . | quote }}
    {{- end }}
    {{- with $route.connectionIdleTimeout }}
    connectionIdleTimeout: {{ . | quote }}
    {{- end }}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "hermetiq-core.partitionMaintenanceName" -}}partition-maintenance{{- end -}}
{{- define "hermetiq-core.progressesPartitionMaintenanceName" -}}progresses-partition-maintenance{{- end -}}
{{- define "hermetiq-core.targetTrendsShortName" -}}target-trends-refresh-short{{- end -}}
{{- define "hermetiq-core.targetTrendsLongName" -}}target-trends-refresh-long{{- end -}}
