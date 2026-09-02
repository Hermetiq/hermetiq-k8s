{{- define "bb-worker-operator.namespace" -}}
{{- default .Release.Namespace .Values.namespaceOverride -}}
{{- end -}}

{{- define "bb-worker-operator.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "bb-worker-operator.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := include "bb-worker-operator.name" . -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "bb-worker-operator.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "bb-worker-operator.labels" -}}
{{- $commonLabels := omit (default dict .Values.commonLabels) "helm.sh/chart" "app.kubernetes.io/name" "app.kubernetes.io/instance" "app.kubernetes.io/version" "app.kubernetes.io/managed-by" "app.kubernetes.io/part-of" -}}
{{- $standardLabels := default (dict) .Values.standardLabels -}}
helm.sh/chart: {{ include "bb-worker-operator.chart" . }}
app.kubernetes.io/name: {{ include "bb-worker-operator.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- if $standardLabels.appVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: buildbarn{{ if $commonLabels }}
{{ include "bb-worker-operator.tplvalues.render" (dict "value" $commonLabels "context" .) }}{{ end }}
{{- end -}}

{{- define "bb-worker-operator.tplvalues.render" -}}
{{- $value := .value -}}
{{- $context := .context -}}
{{- if kindIs "string" $value -}}
{{- tpl $value $context -}}
{{- else -}}
{{- tpl (toYaml $value) $context -}}
{{- end -}}
{{- end -}}

{{- define "bb-worker-operator.commonAnnotations" -}}
{{- with .Values.commonAnnotations }}
{{- include "bb-worker-operator.tplvalues.render" (dict "value" . "context" $) }}
{{- end -}}
{{- end -}}

{{- define "bb-worker-operator.rewriteImageRepository" -}}
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

{{- define "bb-worker-operator.selectorLabels" -}}
app.kubernetes.io/name: {{ include "bb-worker-operator.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: manager
{{- end -}}

{{- define "bb-worker-operator.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "bb-worker-operator.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{- define "bb-worker-operator.image" -}}
{{- $global := default (dict) .Values.global -}}
{{- $repo := required "image.repository is required" .Values.image.repository -}}
{{- $tag := default .Chart.AppVersion .Values.image.tag -}}
{{- $repo = include "bb-worker-operator.rewriteImageRepository" (dict "repository" $repo "registry" $global.imageRegistry) -}}
{{- $image := printf "%s:%s" $repo $tag -}}
{{- with .Values.image.digest -}}
{{- printf "%s@%s" $image (trimPrefix "@" .) -}}
{{- else -}}
{{- $image -}}
{{- end -}}
{{- end -}}

{{- define "bb-worker-operator.imagePullSecrets" -}}
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

{{- define "bb-worker-operator.managerClusterRoleName" -}}
{{- printf "%s-manager" (include "bb-worker-operator.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "bb-worker-operator.leaderElectionRoleName" -}}
{{- printf "%s-leader-election" (include "bb-worker-operator.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "bb-worker-operator.metricsAuthClusterRoleName" -}}
{{- printf "%s-metrics-auth" (include "bb-worker-operator.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "bb-worker-operator.metricsReaderClusterRoleName" -}}
{{- printf "%s-metrics-reader" (include "bb-worker-operator.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "bb-worker-operator.rbeWorkerRolePrefix" -}}
{{- printf "%s-rbeworker" (include "bb-worker-operator.fullname" .) | trunc 53 | trimSuffix "-" -}}
{{- end -}}

{{- define "bb-worker-operator.metricsPortName" -}}
{{- if .Values.metrics.secure -}}https{{- else -}}http{{- end -}}
{{- end -}}

{{- define "bb-worker-operator.metricsScheme" -}}
{{- if .Values.metrics.secure -}}https{{- else -}}http{{- end -}}
{{- end -}}

{{- define "bb-worker-operator.metricsServiceName" -}}
{{- printf "%s-metrics" (include "bb-worker-operator.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "bb-worker-operator.otelServiceName" -}}
{{- default (include "bb-worker-operator.fullname" .) .Values.otel.serviceName -}}
{{- end -}}
