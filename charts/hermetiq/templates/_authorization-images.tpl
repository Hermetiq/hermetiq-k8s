{{/* Reject known pre-authorization images without claiming that an arbitrary
     newer/custom image supports the feature. Digests select the actual image;
     an old tag with a custom digest can legitimately be a patched build. */}}
{{- define "hermetiq-core.validateAuthorizationImage" -}}
{{- $digest := trimPrefix "@" (default "" .digest) -}}
{{- $legacy := false -}}
{{- $field := .tagField -}}
{{- $value := .tag -}}
{{- if $digest -}}
  {{- $legacy = eq $digest .legacyDigest -}}
  {{- $field = .digestField -}}
  {{- $value = .digest -}}
{{- else if regexMatch "^v?(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?(\\+[0-9A-Za-z.-]+)?$" .tag -}}
  {{- /* Compare the numeric release, including its prereleases, but never
       pass arbitrary custom tags to semverCompare. */ -}}
  {{- $release := regexFind "^v?[0-9]+\\.[0-9]+\\.[0-9]+" .tag -}}
  {{- $legacy = semverCompare "<=0.9.8" $release -}}
{{- end -}}
{{- if $legacy -}}
{{- fail (printf "%s=%s selects an image that predates %s; configure matching authorization-capable %s and %s (digest takes precedence over tag). Helm deployments require enforced project authorization and compatible application images" $field $value .feature .tagField .digestField) -}}
{{- end -}}
{{- end -}}

{{- define "hermetiq-core.validateAuthorizationImages" -}}
{{- $core := .Values.images.bepNats -}}
{{- $legacyCore := "sha256:b10a3d3208eb81804d6daf3260ff049324b6d7b37cc26ebd0cfc2c25d91c9118" -}}
{{- include "hermetiq-core.validateAuthorizationImage" (dict "tag" $core.apiTag "digest" $core.apiDigest "tagField" "images.bepNats.apiTag" "digestField" "images.bepNats.apiDigest" "legacyDigest" $legacyCore "feature" "the requested API authorization features") -}}
{{- include "hermetiq-core.validateAuthorizationImage" (dict "tag" $core.pubTag "digest" $core.pubDigest "tagField" "images.bepNats.pubTag" "digestField" "images.bepNats.pubDigest" "legacyDigest" $legacyCore "feature" "the requested publisher authorization features") -}}
{{- include "hermetiq-core.validateAuthorizationImage" (dict "tag" .Values.images.dashboard.tag "digest" .Values.images.dashboard.digest "tagField" "images.dashboard.tag" "digestField" "images.dashboard.digest" "legacyDigest" "sha256:8154cc722cb7cec11b27913a49f6be660f1e9ff3aba68e93c31404fe20c4ca97" "feature" "browser authorization") -}}
{{- /* Enforced access reads the principal lifecycle and project grant schema
     installed by the chart's database bootstrap/migration image. */ -}}
{{- include "hermetiq-core.validateAuthorizationImage" (dict "tag" $core.bootstrapTag "digest" $core.bootstrapDigest "tagField" "images.bepNats.bootstrapTag" "digestField" "images.bepNats.bootstrapDigest" "legacyDigest" $legacyCore "feature" "project authorization database migrations") -}}
{{- if .Values.api.jwt.profiles -}}
{{- include "hermetiq-core.validateAuthorizationImage" (dict "tag" .Values.images.authProxy.tag "digest" .Values.images.authProxy.digest "tagField" "images.authProxy.tag" "digestField" "images.authProxy.digest" "legacyDigest" "sha256:8555a0160ab6adc41a02c029f0eca5a6c3277a7c00c167bff7f73c1459e769dc" "feature" "JWT profile forwarding") -}}
{{- end -}}
{{- end -}}
