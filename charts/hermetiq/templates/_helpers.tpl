{{- define "hermetiq-core.namespace" -}}
{{- default .Release.Namespace .Values.namespaceOverride -}}
{{- end -}}

{{- define "hermetiq-core.buildbarnNamespace" -}}
{{- default .Release.Namespace .Values.bootstrap.projectNamespace -}}
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

{{- define "hermetiq-core.namespaceBrowserUrl" -}}
{{- if .Values.bootstrap.namespaceBrowserUrl -}}
{{- tpl .Values.bootstrap.namespaceBrowserUrl . -}}
{{- else if .Values.hosts.domainBase -}}
{{- printf "https://browser.%s" (tpl .Values.hosts.domainBase .) -}}
{{- end -}}
{{- end -}}

{{- define "hermetiq-core.grafanaDashboardUrl" -}}
{{- if or .Values.hosts.grafana .Values.hosts.domainBase -}}
{{- printf "https://%s/d/hermetiq-demo" (include "hermetiq-core.grafanaHost" .) -}}
{{- end -}}
{{- end -}}

{{- define "hermetiq-core.namespaceDashboardUrl" -}}
{{- if .Values.bootstrap.namespaceDashboardUrl -}}
{{- tpl .Values.bootstrap.namespaceDashboardUrl . -}}
{{- else -}}
{{- include "hermetiq-core.grafanaDashboardUrl" . -}}
{{- end -}}
{{- end -}}

{{- define "hermetiq-core.victoriaMetricsDashboardUrl" -}}
{{- if .Values.victoriaMetrics.dashboardUrl -}}
{{- tpl .Values.victoriaMetrics.dashboardUrl . -}}
{{- else -}}
{{- include "hermetiq-core.grafanaDashboardUrl" . -}}
{{- end -}}
{{- end -}}

{{- define "hermetiq-core.mcpResourceUrl" -}}
{{- default (printf "https://%s" (include "hermetiq-core.mcpHost" .)) .Values.api.mcpResourceUrl -}}
{{- end -}}

{{/* The MCP endpoint URL clients connect to: the <origin>/mcp protected
     resource the server advertises, and the identifier the IdP API should use.
     Every client sends it identically, while a bare origin goes out with or
     without a trailing slash depending on the client. */}}
{{- define "hermetiq-core.mcpEndpointUrl" -}}
{{- printf "%s/mcp" (trimSuffix "/" (include "hermetiq-core.mcpResourceUrl" .)) -}}
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

{{/* publisher.jwks.audience defaults to the public BEP gRPC origin. */}}
{{- define "hermetiq-core.publisherJwksAudience" -}}
{{- if .Values.publisher.jwks.audience -}}
{{- .Values.publisher.jwks.audience -}}
{{- else if or .Values.hosts.bepGrpc .Values.hosts.domainBase -}}
{{- printf "https://%s" (include "hermetiq-core.bepGrpcHost" .) -}}
{{- end -}}
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

{{/* Whether any workload consumes the shared oauth2-proxy ConfigMap and client
     Secret (either the dashboard oauth2-proxy sidecar or the standalone Grafana
     oauth2-proxy when the Grafana Gateway route is enabled). */}}
{{- define "hermetiq-core.oauth2ProxyUsed" -}}
{{- if or .Values.dashboard.oauth2Proxy.enabled (and (eq (include "hermetiq-core.grafanaOauth2ProxyEnabled" .) "true") .Values.gateway.routes.grafanaEnabled) -}}true{{- end -}}
{{- end -}}

{{/* Whether to render the inline oauth2-proxy client Secret (and its checksum).
     Rendered when existingSecret is empty and either:
     - dashboard.oauth2Proxy.enabled is true, or
     - standalone grafana.oauth2Proxy is used and inline client credentials are provided.
     This preserves backwards compatibility for existing values files that set
     dashboard.oauth2Proxy.enabled=false without configuring client credentials. */}}
{{- define "hermetiq-core.oauth2ProxyInlineSecretEnabled" -}}
{{- if and (not .Values.dashboard.oauth2Proxy.client.existingSecret) (or .Values.dashboard.oauth2Proxy.enabled (and (eq (include "hermetiq-core.oauth2ProxyUsed" .) "true") (or .Values.dashboard.oauth2Proxy.client.clientId .Values.dashboard.oauth2Proxy.client.clientSecret .Values.dashboard.oauth2Proxy.client.cookieSecret))) -}}true{{- end -}}
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

{{/* Pod and container securityContexts carry the full CIS Kubernetes
     Benchmark / PSS "restricted" set explicitly. A runAsUser, runAsGroup or
     fsGroup set to null is omitted so the platform can assign it (OpenShift's
     restricted-v2 SCC picks a UID from the namespace range). */}}
{{- define "hermetiq-core.podSecurityContext" -}}
{{- $pod := .Values.security.pod -}}
runAsNonRoot: {{ $pod.runAsNonRoot }}
{{- if not (kindIs "invalid" $pod.runAsUser) }}
runAsUser: {{ $pod.runAsUser }}
{{- end }}
{{- if not (kindIs "invalid" $pod.runAsGroup) }}
runAsGroup: {{ $pod.runAsGroup }}
{{- end }}
{{- if not (kindIs "invalid" $pod.fsGroup) }}
fsGroup: {{ $pod.fsGroup }}
{{- end }}
fsGroupChangePolicy: {{ $pod.fsGroupChangePolicy }}
seccompProfile:
  type: {{ $pod.seccompProfile.type }}
{{- end -}}

{{- define "hermetiq-core.containerSecurityContext" -}}
{{- $pod := .Values.security.pod -}}
allowPrivilegeEscalation: {{ .Values.security.container.allowPrivilegeEscalation }}
privileged: false
readOnlyRootFilesystem: {{ .Values.security.container.readOnlyRootFilesystem }}
runAsNonRoot: {{ $pod.runAsNonRoot }}
{{- if not (kindIs "invalid" $pod.runAsUser) }}
runAsUser: {{ $pod.runAsUser }}
{{- end }}
{{- if not (kindIs "invalid" $pod.runAsGroup) }}
runAsGroup: {{ $pod.runAsGroup }}
{{- end }}
{{- if .Values.security.container.dropCapabilities }}
capabilities:
  drop:
{{- range .Values.security.container.dropCapabilities }}
    - {{ . | quote }}
{{- end }}
{{- end }}
{{- end -}}

{{- define "hermetiq-core.dashboardContainerSecurityContext" -}}
{{- $dashboard := .Values.dashboard.security -}}
allowPrivilegeEscalation: {{ .Values.security.container.allowPrivilegeEscalation }}
privileged: false
readOnlyRootFilesystem: {{ $dashboard.readOnlyRootFilesystem }}
runAsNonRoot: {{ $dashboard.runAsNonRoot }}
{{- if not (kindIs "invalid" $dashboard.runAsUser) }}
runAsUser: {{ $dashboard.runAsUser }}
{{- end }}
{{- if not (kindIs "invalid" $dashboard.runAsGroup) }}
runAsGroup: {{ $dashboard.runAsGroup }}
{{- end }}
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

     With the assistant enabled, the API route always gets a block, even when
     ordinary route timeouts are disabled, and its request and stream limits are
     raised to at least assistant.streamTimeoutSeconds. Otherwise renders nothing
     when gateway.timeouts.enabled is false or the route sets none of the three
     fields. Callers use `with` to decide whether the block exists at all. Each
     field is emitted only when non-empty — an unset field leaves Envoy's own
     default in place, which is not the same as "0s" (0s means *disabled*, not
     *immediate*). */}}
{{- define "hermetiq-core.routeTimeout" -}}
{{- $timeouts := .root.Values.gateway.timeouts | default dict -}}
{{- if and .root.Values.assistant.enabled (eq .route "apiGrpc") -}}
{{- $route := dict -}}
{{- if $timeouts.enabled -}}
{{- $route = index $timeouts .route | default dict -}}
{{- end -}}
{{- $apiGrpc := index $timeouts "apiGrpc" | default dict -}}
timeout:
  http:
    requestTimeout: {{ include "hermetiq-core.assistantTimeout" (dict "root" .root "value" $route.requestTimeout) | quote }}
    maxStreamDuration: {{ include "hermetiq-core.assistantTimeout" (dict "root" .root "value" $route.maxStreamDuration "unset" "0s") | quote }}
    connectionIdleTimeout: {{ default "1h" $apiGrpc.connectionIdleTimeout | quote }}
{{- else if $timeouts.enabled -}}
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

{{/* Milliseconds in a duration such as "300s", "5m", "1h30m" or "250ms".
     Prints -1 for an unbounded value — "0", "0s", "infinity" or
     "infinite" — because Envoy Gateway and Contour read a zero timeout as
     disabled. */}}
{{- define "hermetiq-core.durationMillis" -}}
{{- $d := . | toString | trim | lower -}}
{{- if has $d (list "0" "infinity" "infinite") -}}
-1
{{- else if not (regexMatch "^([0-9]+(\\.[0-9]+)?(h|ms|m|s))+$" $d) -}}
{{- fail (printf "cannot parse timeout %q: use a duration such as 300s, 5m or 1h" $d) -}}
{{- else -}}
{{- $unitMillis := dict "h" 3600000.0 "m" 60000.0 "s" 1000.0 "ms" 1.0 -}}
{{- $millis := 0.0 -}}
{{- range $part := regexFindAll "[0-9]+(\\.[0-9]+)?(h|ms|m|s)" $d -1 -}}
{{- $number := regexFind "^[0-9.]+" $part -}}
{{- $millis = addf $millis (mulf (float64 $number) (index $unitMillis (trimPrefix $number $part))) -}}
{{- end -}}
{{- if eq $millis 0.0 -}}-1{{- else -}}{{ $millis | int }}{{- end -}}
{{- end -}}
{{- end -}}

{{/* A duration timeout on a route that carries Barn Owl streams. Keeps the
     configured value when it is unbounded or at least
     assistant.streamTimeoutSeconds, and otherwise raises it to that. An unset
     value prints .unset, which defaults to the stream timeout.
     Args: dict "root" $ "value" <duration> ["unset" <duration>]. */}}
{{- define "hermetiq-core.assistantTimeout" -}}
{{- $stream := int .root.Values.assistant.streamTimeoutSeconds -}}
{{- $value := toString (default "" .value) | trim -}}
{{- if not $value -}}
{{- default (printf "%ds" $stream) .unset -}}
{{- else -}}
{{- $millis := include "hermetiq-core.durationMillis" $value | atoi -}}
{{- if or (lt $millis 0) (ge $millis (mul $stream 1000)) -}}{{ $value }}{{- else -}}{{ printf "%ds" $stream }}{{- end -}}
{{- end -}}
{{- end -}}

{{/* The larger of a whole-second timeout and assistant.streamTimeoutSeconds,
     for providers with no unbounded setting (nginx ingress, GKE backends).
     Args: dict "root" $ "value" <seconds>. */}}
{{- define "hermetiq-core.assistantTimeoutSeconds" -}}
{{- max (int .value) (int .root.Values.assistant.streamTimeoutSeconds) -}}
{{- end -}}

{{- define "hermetiq-core.partitionMaintenanceName" -}}partition-maintenance{{- end -}}
{{- define "hermetiq-core.progressesPartitionMaintenanceName" -}}progresses-partition-maintenance{{- end -}}
{{- define "hermetiq-core.targetTrendsShortName" -}}target-trends-refresh-short{{- end -}}
{{- define "hermetiq-core.targetTrendsLongName" -}}target-trends-refresh-long{{- end -}}

{{/* Shared CronJob definition for /app/dbadmin maintenance and refresh jobs.
     Args: dict "root" $ "name" <string> "schedule" <string> "workload" <map> "args" <list>. */}}
{{- define "hermetiq-core.dbadminCronJob" -}}
{{- $root := .root -}}
{{- $workload := .workload -}}
apiVersion: batch/v1
kind: CronJob
metadata:
  name: {{ .name }}
  namespace: {{ include "hermetiq-core.namespace" $root }}
  labels:
    {{- include "hermetiq-core.labels" $root | nindent 4 }}
    {{- include "hermetiq-core.componentLabel" (dict "component" "maintenance") | nindent 4 }}
spec:
  schedule: {{ .schedule | quote }}
  {{- if $workload.startingDeadlineSeconds }}
  startingDeadlineSeconds: {{ $workload.startingDeadlineSeconds }}
  {{- end }}
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 1
      {{- if $workload.activeDeadlineSeconds }}
      activeDeadlineSeconds: {{ $workload.activeDeadlineSeconds }}
      {{- end }}
      template:
        metadata:
          labels:
            {{- include "hermetiq-core.podLabels" (dict "root" $root "component" "maintenance") | nindent 12 }}
            {{- include "hermetiq-core.workloadIdentityLabels" $root | nindent 12 }}
        spec:
          serviceAccountName: {{ include "hermetiq-core.serviceAccountName" $root }}
          {{- include "hermetiq-core.automountServiceAccountToken" $workload | nindent 10 }}
          restartPolicy: Never
          securityContext:
            {{- include "hermetiq-core.podSecurityContext" $root | nindent 12 }}
          {{- with include "hermetiq-core.imagePullSecrets" $root }}
{{ . | nindent 10 }}
          {{- end }}
          {{- include "hermetiq-core.podScheduling" (dict "root" $root "workload" $workload) | nindent 10 }}
          containers:
            - name: {{ .name }}
              image: {{ include "hermetiq-core.image" (dict "root" $root "name" "images.bepNats.bootstrap" "repository" $root.Values.images.bepNats.repository "tag" $root.Values.images.bepNats.bootstrapTag "digest" $root.Values.images.bepNats.bootstrapDigest) }}
              imagePullPolicy: {{ $root.Values.images.bepNats.pullPolicy }}
              securityContext:
                {{- include "hermetiq-core.containerSecurityContext" $root | nindent 16 }}
              command:
                - /app/dbadmin
              args:
              {{- range .args }}
                - {{ . }}
              {{- end }}
              env:
{{- with $workload.env }}
{{- include "hermetiq-core.extraEnv" (dict "root" $root "env" .) | trim | nindent 16 }}
{{- end }}
                - name: APP_ENVIRONMENT
                  value: {{ $root.Values.app.environment | quote }}
                - name: DB_HOSTNAME
                  value: {{ required "postgres.host is required" $root.Values.postgres.host | quote }}
                - name: DB_PORT
                  value: {{ required "postgres.port is required" $root.Values.postgres.port | quote }}
                - name: DB_NAME
                  value: {{ required "postgres.database is required" $root.Values.postgres.database | quote }}
                - name: DB_USER
                  value: {{ required "postgres.user is required" $root.Values.postgres.user | quote }}
                - name: DB_PASSWORD
                  valueFrom:
                    secretKeyRef:
                      name: {{ include "hermetiq-core.postgresSecretName" $root }}
                      key: {{ $root.Values.postgres.password.existingSecretKey }}
                - name: PGSSLMODE
                  value: {{ $root.Values.postgres.sslMode | quote }}
              resources:
                {{- toYaml $workload.resources | nindent 16 }}
              volumeMounts:
                - name: tmp
                  mountPath: /tmp
          volumes:
            - name: tmp
              emptyDir:
                sizeLimit: 64Mi
{{- end -}}

{{- define "hermetiq-core.apiAuthProxyRoleEnv" -}}
{{- if .Values.api.jwt.enabled }}
- name: JWT_AUTH_ENABLED
  value: "true"
{{- end }}
{{- with (include "hermetiq-core.apiJwtJwksUrl" .) }}
- name: JWT_JWKS_URL
  value: {{ . | quote }}
{{- end }}
{{- with (include "hermetiq-core.apiJwtIssuer" .) }}
- name: JWT_ISSUER
  value: {{ . | quote }}
{{- end }}
{{- if .Values.api.jwt.audience }}
- name: JWT_AUDIENCE
  value: {{ .Values.api.jwt.audience | quote }}
{{- else if and .Values.api.jwt.enabled .Values.dashboard.oauth2Proxy.enabled }}
- name: JWT_AUDIENCE
  valueFrom:
    secretKeyRef:
      name: {{ include "hermetiq-core.oauth2ProxySecretName" . }}
      key: OAUTH2_PROXY_CLIENT_ID
{{- end }}
{{- if .Values.api.jwt.groupsClaim }}
- name: JWT_GROUPS_CLAIM
  value: {{ .Values.api.jwt.groupsClaim | quote }}
{{- end }}
{{- if .Values.api.jwt.nameClaim }}
- name: JWT_NAME_CLAIM
  value: {{ .Values.api.jwt.nameClaim | quote }}
{{- end }}
{{- if .Values.publisher.hermetiqAdminGroup }}
- name: HERMETIQ_ADMIN_GROUP
  value: {{ .Values.publisher.hermetiqAdminGroup | quote }}
{{- end }}
{{- with (include "hermetiq-core.adminEmails" .) }}
- name: ADMIN_EMAIL_ALLOWLIST
  value: {{ . | quote }}
{{- end }}
{{- with (include "hermetiq-core.authProxyCorsAllowedOrigins" .) }}
- name: CORS_ALLOWED_ORIGINS
  value: {{ . | quote }}
{{- end }}
{{- end -}}

{{- define "hermetiq-core.publisherAuthProxyRoleEnv" -}}
- name: STATIC_FORWARDED_USER
  value: {{ trim .Values.publisher.authProxy.staticForwardedUser | quote }}
{{- end -}}

{{/* Shared grpc-auth-proxy sidecar container spec.
     Args: dict "root" $ "authProxy" <map> "resources" <map> "roleEnv" <string>. */}}
{{- define "hermetiq-core.grpcAuthProxyContainer" -}}
{{- $root := .root -}}
{{- $authProxy := .authProxy -}}
- name: grpc-auth-proxy
  image: {{ include "hermetiq-core.image" (dict "root" $root "name" "images.authProxy" "repository" $root.Values.images.authProxy.repository "tag" $root.Values.images.authProxy.tag "digest" $root.Values.images.authProxy.digest) }}
  imagePullPolicy: {{ $root.Values.images.authProxy.pullPolicy }}
  ports:
    - containerPort: 50081
      protocol: TCP
  env:
{{- with $authProxy.env }}
{{- include "hermetiq-core.extraEnv" (dict "root" $root "env" .) | trim | nindent 4 }}
{{- end }}
    - name: DEBUG
      value: {{ $authProxy.debug | quote }}
    - name: GRPC_PORT
      value: "50081"
    - name: PROXY_PORT
      value: "50091"
{{- with .roleEnv }}
{{ . | trim | nindent 4 }}
{{- end }}
  resources:
    {{- toYaml .resources | nindent 4 }}
  {{- if $authProxy.probes.enabled }}
  livenessProbe:
    {{- include "hermetiq-core.tcpProbe" (dict "port" 50081 "settings" $authProxy.probes.liveness) | nindent 4 }}
  readinessProbe:
    {{- include "hermetiq-core.tcpProbe" (dict "port" 50081 "settings" $authProxy.probes.readiness) | nindent 4 }}
  {{- end }}
  securityContext:
    {{- include "hermetiq-core.containerSecurityContext" $root | nindent 4 }}
{{- end -}}

{{- define "hermetiq-core.assistantPolicyName" -}}
{{- default "bep-aichat-policy" .Values.assistant.policy.existingConfigMap -}}
{{- end -}}
{{- define "hermetiq-core.jevConfigChecksum" -}}
{{- dict "baseUrl" .Values.assistant.jev.baseUrl "secretName" .Values.assistant.jev.apiKey.existingSecret "secretKey" .Values.assistant.jev.apiKey.existingSecretKey "rolloutChecksum" .Values.assistant.jev.rolloutChecksum | toJson | sha256sum -}}
{{- end -}}
{{- define "hermetiq-core.rbeAccessPolicyName" -}}
{{- default "bep-rbe-access-policy" .Values.rbe.accessPolicy.existingConfigMap -}}
{{- end -}}
{{- define "hermetiq-core.assistantPolicyChecksum" -}}
{{- dict "name" (include "hermetiq-core.assistantPolicyName" .) "key" .Values.assistant.policy.configMapKey "data" .Values.assistant.policy.data "externalChecksum" .Values.assistant.policy.rolloutChecksum | toJson | sha256sum -}}
{{- end -}}
{{- define "hermetiq-core.rbeAccessPolicyChecksum" -}}
{{- dict "name" (include "hermetiq-core.rbeAccessPolicyName" .) "key" .Values.rbe.accessPolicy.configMapKey "projects" .Values.rbe.accessPolicy.projects "externalChecksum" .Values.rbe.accessPolicy.rolloutChecksum | toJson | sha256sum -}}
{{- end -}}
