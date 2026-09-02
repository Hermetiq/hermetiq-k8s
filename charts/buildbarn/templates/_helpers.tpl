{{- define "buildbarn.namespace" -}}
{{- default .Release.Namespace .Values.namespaceOverride -}}
{{- end -}}

{{- define "buildbarn.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "buildbarn.labels" -}}
{{- $commonLabels := omit (default dict .Values.commonLabels) "helm.sh/chart" "app.kubernetes.io/name" "app.kubernetes.io/instance" "app.kubernetes.io/version" "app.kubernetes.io/managed-by" "app.kubernetes.io/part-of" "app.kubernetes.io/component" "hermetiq.com/worker-pool" -}}
{{- $standardLabels := default (dict) .Values.standardLabels -}}
helm.sh/chart: {{ include "buildbarn.chart" . }}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- if $standardLabels.appVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: buildbarn{{ if $commonLabels }}
{{ include "buildbarn.tplvalues.render" (dict "value" $commonLabels "context" .) }}{{ end }}
{{- end -}}

{{- define "buildbarn.componentLabel" -}}
app.kubernetes.io/component: {{ required "component is required" .component | quote }}
{{- end -}}

{{/* Stable identity labels for chart-managed Pods. Deliberately excludes
     helm.sh/chart and app.kubernetes.io/version so a chart-only release does
     not roll every workload. Legacy selector/metrics labels are rendered
     separately and cannot be overridden through podLabels. */}}
{{- define "buildbarn.podLabels" -}}
{{- $root := required "root is required" .root -}}
{{- $component := required "component is required" .component -}}
{{- $podLabels := omit (default dict $root.Values.podLabels) "app" "instance" "kubernetes_service" "helm.sh/chart" "app.kubernetes.io/name" "app.kubernetes.io/instance" "app.kubernetes.io/version" "app.kubernetes.io/component" "app.kubernetes.io/part-of" "app.kubernetes.io/managed-by" "hermetiq.com/worker-pool" -}}
app.kubernetes.io/name: {{ $root.Chart.Name }}
app.kubernetes.io/instance: {{ $root.Release.Name }}
app.kubernetes.io/component: {{ $component | quote }}
app.kubernetes.io/managed-by: {{ $root.Release.Service }}
app.kubernetes.io/part-of: buildbarn{{ if $podLabels }}
{{ include "buildbarn.tplvalues.render" (dict "value" $podLabels "context" $root) }}{{ end }}
{{- end -}}

{{- define "buildbarn.preferredPodAntiAffinity" -}}
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

{{- define "buildbarn.requiredPodAntiAffinity" -}}
{{- $app := required "app is required" .app -}}
affinity:
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchLabels:
            app: {{ $app }}
        topologyKey: kubernetes.io/hostname
{{- end -}}

{{- define "buildbarn.tplvalues.render" -}}
{{- $value := .value -}}
{{- $context := .context -}}
{{- if kindIs "string" $value -}}
{{- tpl $value $context -}}
{{- else -}}
{{- tpl (toYaml $value) $context -}}
{{- end -}}
{{- end -}}

{{- define "buildbarn.commonAnnotations" -}}
{{- with .Values.commonAnnotations }}
{{- include "buildbarn.tplvalues.render" (dict "value" . "context" $) }}
{{- end -}}
{{- end -}}

{{- define "buildbarn.rewriteImageRepository" -}}
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

{{- define "buildbarn.image" -}}
{{- $root := required "root is required" .root -}}
{{- $global := default (dict) $root.Values.global -}}
{{- $repo := required (printf "%s.repository is required" .name) .repository -}}
{{- $tag := required (printf "%s.tag is required" .name) .tag -}}
{{- $repo = include "buildbarn.rewriteImageRepository" (dict "repository" $repo "registry" $global.imageRegistry) -}}
{{- $image := printf "%s:%s" $repo $tag -}}
{{- with .digest -}}
{{- printf "%s@%s" $image (trimPrefix "@" .) -}}
{{- else -}}
{{- $image -}}
{{- end -}}
{{- end -}}

{{- define "buildbarn.imageString" -}}
{{- $root := required "root is required" .root -}}
{{- $global := default (dict) $root.Values.global -}}
{{- $image := required (printf "%s.image is required" .name) .image -}}
{{- include "buildbarn.rewriteImageRepository" (dict "repository" $image "registry" $global.imageRegistry) -}}
{{- end -}}

{{- define "buildbarn.configName" -}}buildbarn-config{{- end -}}
{{- define "buildbarn.workerConfigName" -}}buildbarn-worker-config{{- end -}}
{{- define "buildbarn.configChecksum" -}}
{{- $root := .root -}}
{{- $overrides := default dict $root.Values.configOverrides -}}
{{- $parts := list -}}
{{- range $name := .files -}}
  {{- $override := index $overrides $name | default "" -}}
  {{- if $override -}}
    {{- $parts = append $parts (printf "%s:%s" $name $override) -}}
  {{- else -}}
    {{- $parts = append $parts (printf "%s:%s" $name (tpl ($root.Files.Get (printf "files/config/%s" $name)) $root)) -}}
  {{- end -}}
{{- end -}}
{{- join "\n---\n" $parts | sha256sum -}}
{{- end -}}
{{- define "buildbarn.workerConfigChecksum" -}}
{{- $root := .root -}}
{{- $configOverrides := default dict $root.Values.configOverrides -}}
{{- $workerOverrides := default dict $root.Values.workerConfigOverrides -}}
{{- $parts := list -}}
{{- range $name := .files -}}
  {{- if eq $name "common.libsonnet" -}}
    {{- $override := index $configOverrides $name | default "" -}}
    {{- if $override -}}
      {{- $parts = append $parts (printf "%s:%s" $name $override) -}}
    {{- else -}}
      {{- $parts = append $parts (printf "%s:%s" $name (tpl ($root.Files.Get "files/config/common.libsonnet") $root)) -}}
    {{- end -}}
  {{- else -}}
    {{- $override := index $workerOverrides $name | default "" -}}
    {{- if $override -}}
      {{- $parts = append $parts (printf "%s:%s" $name $override) -}}
    {{- else -}}
      {{- $parts = append $parts (printf "%s:%s" $name (tpl ($root.Files.Get (printf "files/worker-config/%s" $name)) $root)) -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- join "\n---\n" $parts | sha256sum -}}
{{- end -}}
{{- define "buildbarn.oauth2ProxyConfigName" -}}
{{- if .Values.browser.oauth2Proxy.existingConfigMap -}}
{{- .Values.browser.oauth2Proxy.existingConfigMap -}}
{{- else -}}
oauth2-proxy-config-browser
{{- end -}}
{{- end -}}
{{- define "buildbarn.oauth2ProxySecretName" -}}
{{- default "oauth2-proxy-client" .Values.browser.oauth2Proxy.client.existingSecret -}}
{{- end -}}

{{- define "buildbarn.browserUrl" -}}
{{- printf "https://%s" (include "buildbarn.browserHost" .) -}}
{{- end -}}

{{- define "buildbarn.browserCorsAllowOrigins" -}}
{{- $origins := .Values.gateway.cors.allowOrigins -}}
{{- if and (not $origins) .Values.ingress.browser.corsAllowOrigin -}}
{{- $origins = splitList "," .Values.ingress.browser.corsAllowOrigin -}}
{{- end -}}
{{- toYaml $origins -}}
{{- end -}}

{{- define "buildbarn.imagePullSecrets" -}}
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

{{- define "buildbarn.routingProvider" -}}
{{- if not .Values.routing.enabled -}}
none
{{- else if eq .Values.routing.provider "none" -}}
none
{{- else -}}
{{- .Values.routing.provider -}}
{{- end -}}
{{- end -}}

{{- define "buildbarn.gatewayNamespace" -}}
{{- default (include "buildbarn.namespace" .) .Values.gateway.namespace -}}
{{- end -}}

{{- define "buildbarn.parentRefs" -}}
{{- if .Values.gateway.parentRefs }}
{{- tpl (toYaml .Values.gateway.parentRefs) . }}
{{- else }}
- name: {{ required "gateway.name is required when active routing.provider is gateway or gateway-httproute-only" .Values.gateway.name | quote }}
{{- if ne (include "buildbarn.gatewayNamespace" .) (include "buildbarn.namespace" .) }}
  namespace: {{ include "buildbarn.gatewayNamespace" . | quote }}
{{- end }}
{{- end }}
{{- end -}}

{{- define "buildbarn.httpProxyTimeoutPolicy" -}}
response: {{ .Values.httpProxy.responseTimeout | quote }}
{{- with .Values.httpProxy.idleTimeout }}
idle: {{ . | quote }}
{{- end }}
{{- with .Values.httpProxy.idleConnectionTimeout }}
idleConnection: {{ . | quote }}
{{- end }}
{{- end -}}

{{- define "buildbarn.tlsSecretName" -}}
{{- if .Values.tls.secretName -}}
{{- .Values.tls.secretName -}}
{{- else -}}
{{- .Values.certificate.name -}}
{{- end -}}
{{- end -}}

{{/*
Render a BackendTrafficPolicy `circuitBreaker` block from a backendTrafficPolicy
value dict. Call with that dict as the context. Emits nothing unless
.circuitBreaker.enabled, so routes that want Envoy Gateway's defaults are
unaffected.

Every field defaults to 1024 in the Envoy Gateway CRD and applies PER CLUSTER,
not per endpoint — adding frontend replicas does not raise these budgets. A field
left null (or 0) is omitted so Envoy's own default applies.
*/}}
{{- define "buildbarn.circuitBreaker" -}}
{{- $cb := .circuitBreaker -}}
{{- if and $cb $cb.enabled }}
  circuitBreaker:
{{- range $field := list "maxConnections" "maxPendingRequests" "maxParallelRequests" "maxParallelRetries" "maxRequestsPerConnection" }}
{{- $value := index $cb $field }}
{{- if $value }}
    {{ $field }}: {{ int64 $value }}
{{- end }}
{{- end }}
{{- end }}
{{- end -}}

{{- define "buildbarn.storageSizeGi" -}}
{{- $name := .name -}}
{{- $value := .value | toString -}}
{{- if hasSuffix "Ti" $value -}}
{{- mul (int (trimSuffix "Ti" $value)) 1024 -}}
{{- else if hasSuffix "Gi" $value -}}
{{- int (trimSuffix "Gi" $value) -}}
{{- else -}}
{{- fail (printf "%s (%s) must be an integer Gi or Ti quantity" $name $value) -}}
{{- end -}}
{{- end -}}

{{- define "buildbarn.storageSizeMi" -}}
{{- $name := .name -}}
{{- $value := .value | toString -}}
{{- if hasSuffix "Ti" $value -}}
{{- mul (int (trimSuffix "Ti" $value)) 1048576 -}}
{{- else if hasSuffix "Gi" $value -}}
{{- mul (int (trimSuffix "Gi" $value)) 1024 -}}
{{- else if hasSuffix "Mi" $value -}}
{{- int (trimSuffix "Mi" $value) -}}
{{- else -}}
{{- fail (printf "%s (%s) must be an integer Mi, Gi, or Ti quantity" $name $value) -}}
{{- end -}}
{{- end -}}

{{- define "buildbarn.podScheduling" -}}
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

{{- define "buildbarn.automountServiceAccountToken" -}}
{{- $root := .root -}}
{{- $workload := default (dict) .workload -}}
{{- $globalServiceAccount := default (dict) $root.Values.serviceAccount -}}
{{- $value := $globalServiceAccount.automountServiceAccountToken -}}
{{- if and (hasKey $workload "automountServiceAccountToken") (ne $workload.automountServiceAccountToken nil) -}}
{{- $value = $workload.automountServiceAccountToken -}}
{{- end -}}
{{- if kindIs "bool" $value }}
automountServiceAccountToken: {{ $value }}
{{- end }}
{{- end -}}

{{- define "buildbarn.host" -}}
{{- $root := .root -}}
{{- $value := default "" .value -}}
{{- if $value -}}
{{- tpl $value $root -}}
{{- else -}}
{{- $base := required "hosts.domainBase is required" $root.Values.hosts.domainBase -}}
{{- $base = tpl $base $root -}}
{{- printf "%s.%s" .subdomain $base -}}
{{- end -}}
{{- end -}}

{{- define "buildbarn.browserHost" -}}
{{- include "buildbarn.host" (dict "root" . "value" .Values.hosts.browser "subdomain" "browser") -}}
{{- end -}}

{{- define "buildbarn.frontendGrpcHost" -}}
{{- include "buildbarn.host" (dict "root" . "value" .Values.hosts.frontendGrpc "subdomain" "bb") -}}
{{- end -}}

{{- define "buildbarn.rbeWebHost" -}}
{{- include "buildbarn.host" (dict "root" . "value" .Values.hosts.rbeWeb "subdomain" "rbe-web") -}}
{{- end -}}

{{- define "buildbarn.remoteAssetHost" -}}
{{- include "buildbarn.host" (dict "root" . "value" .Values.hosts.remoteAsset "subdomain" "asset") -}}
{{- end -}}

{{- define "buildbarn.portalHost" -}}
{{- include "buildbarn.host" (dict "root" . "value" .Values.hosts.portal "subdomain" "portal") -}}
{{- end -}}

{{- define "buildbarn.besHost" -}}
{{- include "buildbarn.host" (dict "root" . "value" .Values.hosts.bes "subdomain" "bes") -}}
{{- end -}}

{{- define "buildbarn.browserServicePort" -}}
{{- if .Values.browser.service.targetPortOverride -}}
{{- .Values.browser.service.targetPortOverride -}}
{{- else if .Values.browser.oauth2Proxy.enabled -}}
80
{{- else -}}
7984
{{- end -}}
{{- end -}}

{{- define "buildbarn.browserServicePortName" -}}
{{- if or .Values.browser.service.targetPortOverride .Values.browser.oauth2Proxy.enabled -}}proxy{{- else -}}http{{- end -}}
{{- end -}}

{{- define "buildbarn.browserServiceTargetPort" -}}
{{- if .Values.browser.service.targetPortOverride -}}
{{- .Values.browser.service.targetPortOverride -}}
{{- else if .Values.browser.oauth2Proxy.enabled -}}
proxy
{{- else -}}
7984
{{- end -}}
{{- end -}}

{{- define "buildbarn.frontendGrpcTargetPort" -}}
{{- if .Values.frontend.grpcCacheProxy.enabled -}}
{{- .Values.frontend.grpcCacheProxy.port -}}
{{- else -}}
8980
{{- end -}}
{{- end -}}

{{/*
Message-size limit for the grpc-cache-proxy sidecar. Never below the frontend's
own maximumMessageSizeBytes: the sidecar sits in front of it, so a smaller limit
here would reject responses the frontend is happy to send, surfacing as
ResourceExhausted from a component the operator isn't thinking about.
*/}}
{{- define "buildbarn.grpcCacheProxyMaxMessageSize" -}}
{{- max (int .Values.frontend.grpcCacheProxy.maxMessageSizeBytes) (int .Values.config.maximumMessageSizeBytes) -}}
{{- end -}}

{{/*
OTLP endpoint for the grpc-cache-proxy sidecar. The proxy initializes its OTEL
exporter unconditionally, so omitting OTEL_EXPORTER_OTLP_ENDPOINT makes the SDK
fall back to localhost:4317.
*/}}
{{- define "buildbarn.grpcCacheProxyOtelEndpoint" -}}
{{- $proxy := .Values.frontend.grpcCacheProxy -}}
{{- $scheme := ternary "https" "http" (and .Values.tracing.enabled .Values.tracing.tls.enabled) -}}
{{- if $proxy.otel.endpoint -}}
{{- $proxy.otel.endpoint -}}
{{- else if and .Values.tracing.enabled .Values.tracing.nodeLocal.enabled -}}
{{- printf "%s://$(K8S_LOCAL_NODE_IP):%v" $scheme .Values.tracing.nodeLocal.port -}}
{{- else if and .Values.tracing.enabled .Values.tracing.endpoint -}}
{{- printf "%s://%s" $scheme .Values.tracing.endpoint -}}
{{- else -}}
{{- printf "http://%s:4317" (required "hosts.otel is required when frontend.grpcCacheProxy is enabled and Buildbarn tracing is not providing an endpoint; set hosts.otel or frontend.grpcCacheProxy.otel.endpoint" .Values.hosts.otel) -}}
{{- end -}}
{{- end -}}

{{- define "buildbarn.tracingEnv" -}}
{{- $root := .root -}}
{{- if $root.Values.tracing.enabled }}
- name: SERVICE_NAME
  value: {{ .serviceName | quote }}
{{- if $root.Values.tracing.nodeLocal.enabled }}
- name: K8S_LOCAL_NODE_IP
  valueFrom:
    fieldRef:
      apiVersion: v1
      fieldPath: status.hostIP
{{- end }}
{{- end }}
{{- end -}}

{{- define "buildbarn.tracingVolumeMount" -}}
{{- if and .Values.tracing.enabled .Values.tracing.tls.clientCertificate.enabled }}
- name: tracing-mtls-client-cert
  readOnly: true
  mountPath: {{ .Values.tracing.tls.clientCertificate.mountPath | quote }}
{{- end }}
{{- end -}}

{{- define "buildbarn.tracingVolume" -}}
{{- if and .Values.tracing.enabled .Values.tracing.tls.clientCertificate.enabled }}
- name: tracing-mtls-client-cert
  secret:
    secretName: {{ default .Values.secrets.mtlsClientCert .Values.tracing.tls.clientCertificate.secretName | quote }}
{{- end }}
{{- end -}}

{{/*
Storage-tier persistence helpers. A "store" is one of cas/ac/iscc/fsac. Each has
`.backend` (filesystem|blockDevice). In blockDevice mode the blocks live on a raw
volumeMode:Block volume (claim "<store>-blocks", surfaced at /dev/bb/<store>); when
`.blockDevice.keyLocationMap == "file"` a small Filesystem volume (claim "<store>-meta",
mounted at /storage-<store>-meta) holds the KLM file + persistent_state.
*/}}

{{- define "buildbarn.storage.storeList" -}}
{{- $stores := list "cas" "ac" -}}
{{- if .Values.storage.persistence.iscc.enabled -}}{{- $stores = append $stores "iscc" -}}{{- end -}}
{{- if .Values.storage.persistence.fsac.enabled -}}{{- $stores = append $stores "fsac" -}}{{- end -}}
{{- join " " $stores -}}
{{- end -}}

{{- define "buildbarn.storage.anyBlock" -}}
{{- range $store := splitList " " (include "buildbarn.storage.storeList" .) -}}
{{- if eq (index $.Values.storage.persistence $store).backend "blockDevice" -}}true{{- end -}}
{{- end -}}
{{- end -}}

{{- define "buildbarn.storage.anyFsPrep" -}}
{{- range $store := splitList " " (include "buildbarn.storage.storeList" .) -}}
{{- $s := index $.Values.storage.persistence $store -}}
{{- if or (ne $s.backend "blockDevice") (eq $s.blockDevice.keyLocationMap "file") -}}true{{- end -}}
{{- end -}}
{{- end -}}

{{/* Directories that need to exist on a filesystem, one per prepared store. */}}
{{- define "buildbarn.storage.fsDirs" -}}
{{- $dirs := list -}}
{{- range $store := splitList " " (include "buildbarn.storage.storeList" .) -}}
{{- $s := index $.Values.storage.persistence $store -}}
{{- if ne $s.backend "blockDevice" -}}
{{- $dirs = append $dirs (printf "/storage-%s" $store) -}}
{{- else if eq $s.blockDevice.keyLocationMap "file" -}}
{{- $dirs = append $dirs (printf "/storage-%s-meta" $store) -}}
{{- end -}}
{{- end -}}
{{- join " " $dirs -}}
{{- end -}}

{{/* volumeMounts for the filesystem/metadata volumes (main + volume-init). No leading/trailing newline. */}}
{{- define "buildbarn.storage.fsVolumeMounts" -}}
{{- $root := . -}}
{{- $lines := list -}}
{{- range $store := splitList " " (include "buildbarn.storage.storeList" $root) -}}
{{- $s := index $root.Values.storage.persistence $store -}}
{{- if ne $s.backend "blockDevice" -}}
{{- $lines = append $lines (printf "- mountPath: /storage-%s\n  name: %s" $store $store) -}}
{{- else if eq $s.blockDevice.keyLocationMap "file" -}}
{{- $lines = append $lines (printf "- mountPath: /storage-%s-meta\n  name: %s-meta" $store $store) -}}
{{- end -}}
{{- end -}}
{{- join "\n" $lines -}}
{{- end -}}

{{/* volumeDevices for raw block PVCs (pvc mode: main + device-chown init). No leading/trailing newline. */}}
{{- define "buildbarn.storage.volumeDevices" -}}
{{- $root := . -}}
{{- $lines := list -}}
{{- range $store := splitList " " (include "buildbarn.storage.storeList" $root) -}}
{{- $s := index $root.Values.storage.persistence $store -}}
{{- if eq $s.backend "blockDevice" -}}
{{- $lines = append $lines (printf "- devicePath: /dev/bb/%s\n  name: %s-blocks" $store $store) -}}
{{- end -}}
{{- end -}}
{{- join "\n" $lines -}}
{{- end -}}

{{/*
volumeMounts that bind-mount raw block device NODES (hostPath mode only). Kubernetes
`volumeDevices` can only reference a PVC/ephemeral source, never hostPath, so a
node-local device (e.g. an LVM LV from partition_ephemeral_disks) is bind-mounted as a
device-node volumeMount instead. Opening it also needs a privileged container (the
device cgroup only allowlists PVC-attached devices). No leading/trailing newline.
*/}}
{{- define "buildbarn.storage.blockDeviceMounts" -}}
{{- $root := . -}}
{{- $lines := list -}}
{{- range $store := splitList " " (include "buildbarn.storage.storeList" $root) -}}
{{- $s := index $root.Values.storage.persistence $store -}}
{{- if eq $s.backend "blockDevice" -}}
{{- $lines = append $lines (printf "- mountPath: /dev/bb/%s\n  name: %s-blocks" $store $store) -}}
{{- end -}}
{{- end -}}
{{- join "\n" $lines -}}
{{- end -}}

{{/* Shell script for the volume-init container: prepare each filesystem/metadata dir. Column 0. */}}
{{/*
Prepare the filesystem-backed store directories. In hostPath mode this runs as
root and chowns first: the kubelet creates a DirectoryOrCreate hostPath as
root:root 0755, and fsGroup is not applied to hostPath volumes, so the non-root
storage container (and an unprivileged init container) cannot write into it.
pvc and emptyDir volumes do get fsGroup, so there the mkdir runs unprivileged.
*/}}
{{- define "buildbarn.storage.volumeInitScript" -}}
set -eu
{{- $hostPath := eq .Values.storage.persistence.mode "hostPath" -}}
{{- range $dir := splitList " " (include "buildbarn.storage.fsDirs" .) }}
{{- if $hostPath }}
chown 65534:65534 {{ $dir }}
{{- end }}
mkdir -p {{ $dir }}/persistent_state
chmod 0700 {{ $dir }}/persistent_state
{{- if $hostPath }}
chown 65534:65534 {{ $dir }}/persistent_state
{{- end }}
{{- end }}
{{- end -}}

{{/*
securityContext for the volume-init container. hostPath mode needs root plus
CHOWN/FOWNER to take ownership of the kubelet-created directory; every other
mode runs unprivileged as the storage uid.
*/}}
{{- define "buildbarn.storage.volumeInitSecurityContext" -}}
{{- if eq .Values.storage.persistence.mode "hostPath" }}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
runAsNonRoot: false
runAsUser: 0
capabilities:
  drop:
    - ALL
  add:
    - CHOWN
    - FOWNER
    - DAC_OVERRIDE
{{- else }}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
runAsNonRoot: true
runAsUser: 65534
runAsGroup: 65534
capabilities:
  drop:
    - ALL
{{- end }}
{{- end -}}

{{/* PVC volumeClaimTemplates for mode=pvc. No leading/trailing newline. */}}
{{- define "buildbarn.storage.volumeClaimTemplates" -}}
{{- $root := . -}}
{{- $lines := list -}}
{{- range $store := splitList " " (include "buildbarn.storage.storeList" $root) -}}
{{- $s := index $root.Values.storage.persistence $store -}}
{{- if ne $s.backend "blockDevice" -}}
{{- $lines = append $lines (printf "- metadata:\n    name: %s\n  spec:\n    accessModes:\n      - ReadWriteOnce\n    storageClassName: %s\n    resources:\n      requests:\n        storage: %s" $store (toString $s.storageClassName) (toString $s.size)) -}}
{{- else -}}
{{- $lines = append $lines (printf "- metadata:\n    name: %s-blocks\n  spec:\n    accessModes:\n      - ReadWriteOnce\n    volumeMode: Block\n    storageClassName: %s\n    resources:\n      requests:\n        storage: %s" $store (toString $s.blockDevice.storageClassName) (toString $s.blockDevice.size)) -}}
{{- if eq $s.blockDevice.keyLocationMap "file" -}}
{{- $lines = append $lines (printf "- metadata:\n    name: %s-meta\n  spec:\n    accessModes:\n      - ReadWriteOnce\n    storageClassName: %s\n    resources:\n      requests:\n        storage: %s" $store (toString $s.blockDevice.metadata.storageClassName) (toString $s.blockDevice.metadata.size)) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- join "\n" $lines -}}
{{- end -}}

{{/* Pod-level `volumes:` entries for non-pvc modes (emptyDir/hostPath), incl. hostPath block/meta. No leading/trailing newline. */}}
{{- define "buildbarn.storage.podStoreVolumes" -}}
{{- $root := . -}}
{{- $mode := $root.Values.storage.persistence.mode -}}
{{- $lines := list -}}
{{- range $store := splitList " " (include "buildbarn.storage.storeList" $root) -}}
{{- $s := index $root.Values.storage.persistence $store -}}
{{- if ne $s.backend "blockDevice" -}}
{{- if eq $mode "emptyDir" -}}
{{- if $s.emptyDir.sizeLimit -}}
{{- $lines = append $lines (printf "- name: %s\n  emptyDir:\n    sizeLimit: %s" $store (quote (toString $s.emptyDir.sizeLimit))) -}}
{{- else -}}
{{- $lines = append $lines (printf "- name: %s\n  emptyDir:\n    {}" $store) -}}
{{- end -}}
{{- else if eq $mode "hostPath" -}}
{{- $lines = append $lines (printf "- name: %s\n  hostPath:\n    path: %s\n    type: %s" $store (quote (toString $s.hostPath.path)) (toString $s.hostPath.type)) -}}
{{- end -}}
{{- else if eq $mode "hostPath" -}}
{{- $dev := required (printf "storage.persistence.%s.blockDevice.hostPath.devicePath is required for backend=blockDevice with mode=hostPath" $store) $s.blockDevice.hostPath.devicePath -}}
{{- $lines = append $lines (printf "- name: %s-blocks\n  hostPath:\n    path: %s\n    type: BlockDevice" $store (quote (toString $dev))) -}}
{{- if eq $s.blockDevice.keyLocationMap "file" -}}
{{- $mp := required (printf "storage.persistence.%s.blockDevice.metadata.hostPath.path is required for keyLocationMap=file with mode=hostPath" $store) $s.blockDevice.metadata.hostPath.path -}}
{{- $lines = append $lines (printf "- name: %s-meta\n  hostPath:\n    path: %s\n    type: %s" $store (quote (toString $mp)) (toString $s.blockDevice.metadata.hostPath.type)) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- join "\n" $lines -}}
{{- end -}}

{{/* Pod securityContext for storage volumes and raw device group access. Column 0. */}}
{{- define "buildbarn.storage.podSecurityContext" -}}
{{- $bd := .Values.storage.persistence.blockDevice }}
securityContext:
  runAsNonRoot: true
  runAsUser: 65534
  runAsGroup: 65534
  fsGroup: {{ $bd.fsGroup }}
  fsGroupChangePolicy: OnRootMismatch
  {{- if (include "buildbarn.storage.anyBlock" .) }}
  {{- with $bd.supplementalGroups }}
  supplementalGroups:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- end }}
  seccompProfile:
    type: RuntimeDefault
{{- end -}}

{{/* Privileged-lite init container that chowns raw device nodes (deviceAccess=chownInit). Column 0. */}}
{{- define "buildbarn.storage.deviceChownInit" -}}
{{- $bd := .Values.storage.persistence.blockDevice }}
- name: device-chown
  image: {{ include "buildbarn.imageString" (dict "root" . "name" "images.busybox" "image" .Values.images.busybox.image) | quote }}
  imagePullPolicy: {{ .Values.images.busybox.pullPolicy }}
  command:
    - sh
    - -c
    - |
      set -eu
      for dev in {{ range $store := splitList " " (include "buildbarn.storage.storeList" .) }}{{ $s := index $.Values.storage.persistence $store }}{{ if eq $s.backend "blockDevice" }}/dev/bb/{{ $store }} {{ end }}{{ end }}; do
        if [ -b "$dev" ]; then
          chown 65534:65534 "$dev"
          chmod 0600 "$dev"
        fi
      done
  {{- if $bd.deviceInit.securityContext }}
  securityContext:
    {{- toYaml $bd.deviceInit.securityContext | nindent 4 }}
  {{- else }}
  securityContext:
    runAsUser: 0
    runAsNonRoot: false
    allowPrivilegeEscalation: {{ $bd.deviceInit.privileged }}
    readOnlyRootFilesystem: true
    capabilities:
      drop:
        - ALL
      add:
        - CHOWN
        - FOWNER
        - DAC_OVERRIDE
    {{- if $bd.deviceInit.privileged }}
    privileged: true
    {{- end }}
  {{- end }}
  {{- if eq .Values.storage.persistence.mode "hostPath" }}
  volumeMounts:
    {{- include "buildbarn.storage.blockDeviceMounts" . | nindent 4 }}
  {{- else }}
  volumeDevices:
    {{- include "buildbarn.storage.volumeDevices" . | nindent 4 }}
  {{- end }}
{{- end -}}
