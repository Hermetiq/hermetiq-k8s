local common = import 'common.libsonnet';
{{- if .Values.scheduler.configurationReloadInterval }}
local routing = import 'scheduler-routing.libsonnet';
{{- end }}
{{- if .Values.scheduler.handover.enabled }}
local podIP = std.extVar('POD_IP');
local podHost = if std.length(std.findSubstr(':', podIP)) > 0 then '[' + podIP + ']' else podIP;
{{- end }}

{
  deprecatedAdminHttpServers: [{
    listenAddresses: [':7982'],
    {{ include "buildbarn.httpAuthenticationPolicy" (dict "root" $ "config" .Values.scheduler.adminHttpServers.authenticationPolicy "path" "scheduler.adminHttpServers.authenticationPolicy" "compact" true) | indent 4 | trim }}
  }],
  clientGrpcServers: [{
    listenAddresses: [':8982'],
    {{- if .Values.security.grpcMtls.enabled }}
    {{ include "buildbarn.mtlsServerTls" . | indent 4 | trim }}
    {{- end }}
    {{ include "buildbarn.authenticationPolicy" (dict "root" $ "config" .Values.scheduler.clientGrpcServers.authenticationPolicy "path" "scheduler.clientGrpcServers.authenticationPolicy" "compact" true) | indent 4 | trim }}
  }],
  workerGrpcServers: [{
    listenAddresses: [':8983'],
    {{- if .Values.security.grpcMtls.enabled }}
    {{ include "buildbarn.mtlsServerTls" . | indent 4 | trim }}
    {{- end }}
    {{ include "buildbarn.authenticationPolicy" (dict "root" $ "config" .Values.scheduler.workerGrpcServers.authenticationPolicy "path" "scheduler.workerGrpcServers.authenticationPolicy" "compact" true) | indent 4 | trim }}
  }],
  buildQueueStateGrpcServers: [{
    listenAddresses: [':8984'],
    {{- if .Values.security.grpcMtls.enabled }}
    {{ include "buildbarn.mtlsServerTls" . | indent 4 | trim }}
    {{- end }}
    {{ include "buildbarn.authenticationPolicy" (dict "root" $ "config" .Values.scheduler.buildQueueStateGrpcServers.authenticationPolicy "path" "scheduler.buildQueueStateGrpcServers.authenticationPolicy" "compact" true) | indent 4 | trim }}
  }],
  {{- if .Values.scheduler.handover.enabled }}
  handoverGrpcServers: [{
    listenAddresses: [':{{ .Values.scheduler.handover.port }}'],
    {{- if .Values.security.grpcMtls.enabled }}
    {{ include "buildbarn.mtlsServerTls" . | indent 4 | trim }}
    {{- end }}
    {{ include "buildbarn.authenticationPolicy" (dict "root" $ "config" .Values.scheduler.handover.handoverGrpcServers.authenticationPolicy "path" "scheduler.handover.handoverGrpcServers.authenticationPolicy" "compact" true) | indent 4 | trim }}
  }],
  coordinator: {
    client: {
      address: 'unix:///run/bb-coordinator/coordinator.sock',
    },
    selfId: std.extVar('POD_NAME'),
    selfClientEndpoint: podHost + ':8982',
    selfWorkerEndpoint: podHost + ':8983',
    selfStateEndpoint: podHost + ':8984',
    selfHandoverEndpoint: podHost + ':{{ .Values.scheduler.handover.port }}',
    {{- if .Values.security.grpcMtls.enabled }}
    peerClientTemplate: {
      {{ include "buildbarn.mtlsClientTls" (dict "Values" .Values "serverName" .Values.scheduler.handover.peerServerName) | indent 6 | trim }}
    },
    {{- end }}
    adoptionWindow: {{ .Values.scheduler.handover.adoptionWindow | quote }},
    recoveredOperationGracePeriod: {{ .Values.scheduler.handover.recoveredOperationGracePeriod | quote }},
    relayDrainPeriod: {{ .Values.scheduler.handover.relayDrainPeriod | quote }},
  },
  {{- end }}
  deprecatedPortalUrl: common.portalUrl,
  contentAddressableStorage: common.blobstore.contentAddressableStorage,
  {{- if .Values.scheduler.sizeClassAnalysis.enabled }}
  initialSizeClassCache: common.initialSizeClassCache,
  {{- end }}
  maximumMessageSizeBytes: common.maximumMessageSizeBytes,
  global: common.global,
  executeAuthorizer: { allow: {} },
  modifyDrainsAuthorizer: { allow: {} },
  killOperationsAuthorizer: { allow: {} },
  synchronizeAuthorizer: { allow: {} },
  {{- if .Values.scheduler.configurationReloadInterval }}
  configurationReloadInterval: {{ .Values.scheduler.configurationReloadInterval | quote }},
  {{- else }}
  {{ include "buildbarn.schedulerRouting" . }}
  {{- end }}
  platformQueueWithNoWorkersTimeout: {{ .Values.scheduler.platformQueueWithNoWorkersTimeout | quote }},
}{{ if .Values.scheduler.configurationReloadInterval }} + routing{{ end }}
