local common = import 'common.libsonnet';

{
  adminHttpServers: [{
    listenAddresses: [':7982'],
    authenticationPolicy: { allow: {} },
  }],
  clientGrpcServers: [{
    listenAddresses: [':8982'],
    authenticationPolicy: { allow: {} },
  }],
  workerGrpcServers: [{
    listenAddresses: [':8983'],
    authenticationPolicy: { allow: {} },
  }],
  buildQueueStateGrpcServers: [{
    listenAddresses: [':8984'],
    authenticationPolicy: { allow: {} },
  }],
  browserUrl: common.browserUrl,
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
  actionRouter: {
    simple: {
      platformKeyExtractor: { action: {} },
      invocationKeyExtractors: [
        { correlatedInvocationsId: {} },
        { toolInvocationId: {} },
      ],
      initialSizeClassAnalyzer: {
        defaultExecutionTimeout: {{ .Values.scheduler.defaultExecutionTimeout | quote }},
        maximumExecutionTimeout: {{ .Values.scheduler.maximumExecutionTimeout | quote }},
        {{- if .Values.scheduler.sizeClassAnalysis.enabled }}
        feedbackDriven: {
          failureCacheDuration: {{ .Values.scheduler.sizeClassAnalysis.failureCacheDuration | quote }},
          historySize: {{ .Values.scheduler.sizeClassAnalysis.historySize }},
          pageRank: {
            acceptableExecutionTimeIncreaseExponent: {{ .Values.scheduler.sizeClassAnalysis.pageRank.acceptableExecutionTimeIncreaseExponent }},
            smallerSizeClassExecutionTimeoutMultiplier: {{ .Values.scheduler.sizeClassAnalysis.pageRank.smallerSizeClassExecutionTimeoutMultiplier }},
            minimumExecutionTimeout: {{ .Values.scheduler.sizeClassAnalysis.pageRank.minimumExecutionTimeout | quote }},
            maximumConvergenceError: {{ .Values.scheduler.sizeClassAnalysis.pageRank.maximumConvergenceError }},
          },
        },
        {{- end }}
      },
    },
  },
  {{- if .Values.scheduler.predeclaredPlatformQueues }}
  predeclaredPlatformQueues: [
    {{- range .Values.scheduler.predeclaredPlatformQueues }}
    {
      {{- if .instanceNamePrefix }}
      instanceNamePrefix: {{ .instanceNamePrefix | quote }},
      {{- end }}
      platform: { properties: {{ .platform | toJson }} },
      sizeClasses: {{ .sizeClasses | toJson }},
    },
    {{- end }}
  ],
  {{- end }}
  platformQueueWithNoWorkersTimeout: {{ .Values.scheduler.platformQueueWithNoWorkersTimeout | quote }},
}
