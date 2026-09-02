local common = import 'common.libsonnet';

{
  global: common.global,
  maximumMessageSizeBytes: common.maximumMessageSizeBytes,
  instanceNameAuthorizer: { allow: {} },
  httpServers: [{
    listenAddresses: [':8081'],
    authenticationPolicy: { allow: {} },
  }],

  besServiceConfiguration: {
    grpcServers: [{
      listenAddresses: [':8082'],
      authenticationPolicy: { allow: {} },
      // Individual build events are small; this is independent of the shared
      // common.maximumMessageSizeBytes used for blob traffic.
      maximumReceivedMessageSizeBytes: 10 * 1024 * 1024,
    }],
    database: {
      postgres: {
        connectionString: std.extVar('DB_CONNECTION_STRING'),
      },
      connectionPoolConfiguration: {
        maxOpenConnections: {{ int .Values.portal.db.connectionPool.maxOpenConnections }},
        maxIdleConnections: {{ int .Values.portal.db.connectionPool.maxIdleConnections }},
        connectionMaxLifetime: '{{ .Values.portal.db.connectionPool.connectionMaxLifetime }}',
        connectionMaxIdleTime: '{{ .Values.portal.db.connectionPool.connectionMaxIdleTime }}',
      },
    },
    enableBepFileUpload: {{ .Values.portal.bes.enableBepFileUpload }},
    enableGraphqlPlayground: {{ .Values.portal.bes.enableGraphqlPlayground }},
    saveDataLevel: { basicAndTarget: {} },
    databaseCleanupConfiguration: {
      cleanupInterval: '{{ .Values.portal.bes.cleanup.cleanupInterval }}',
      invocationMessageTimeout: '{{ .Values.portal.bes.cleanup.invocationMessageTimeout }}',
      invocationRetention: '{{ .Values.portal.bes.cleanup.invocationRetention }}',
    },
    minEventBatchDuration: '{{ .Values.portal.bes.minEventBatchDuration }}',
{{- with .Values.portal.bes.buildKey }}
    buildKey: {{ . | quote }},
{{- end }}
{{- with .Values.portal.bes.invocationMetadataExtractor }}
    // Populates username/hostname/sourceControls/invocationTags/buildTags from
    // Bazel's environment. buildKey above reads from the buildTags it returns.
    invocationMetadataExtractor: {{ toJson . }},
{{- end }}
  },

  // Blob browsing reads the storage shards directly: the chart has no plain
  // in-cluster frontend Service, and routing portal reads through
  // frontend-grpc would push them through the optional grpc-cache-proxy
  // sidecar, polluting cache-event analytics. ISCC/FSAC views light up only
  // when those stores are enabled in common.libsonnet.
  contentAddressableStorage: common.blobstore.contentAddressableStorage,
  actionCache: common.blobstore.actionCache,
  [if std.objectHas(common, 'initialSizeClassCache') then 'initialSizeClassCache']: common.initialSizeClassCache,
  [if std.objectHas(common, 'fileSystemAccessCache') then 'fileSystemAccessCache']: common.fileSystemAccessCache,

  schedulerServiceConfiguration: {
    buildQueueStateClient: {
      address: 'scheduler:8984',
    },
    killOperationsAuthorizer: {
      allow: {},
    },
    listOperationsPageSize: 500,
  },

  // The web UI ships inside the binary; this config is injected into
  // index.html as it is served. Each feature flag is a presence-only message,
  // so an absent key disables the page.
  frontendServiceConfiguration: {
    frontendSource: { embedded: {} },
    frontendConfig: {
      companyName: {{ .Values.portal.frontend.companyName | quote }},
      // Shown to users as the --bes_backend value to point Bazel at.
      grpcBackendUrl: 'grpcs://{{ include "buildbarn.besHost" . }}',
      featureFlags: {
        home: {
{{- if .Values.portal.frontend.featureFlags.home.fileUpload }}
          fileUpload: {},
{{- end }}
{{- if .Values.portal.frontend.featureFlags.home.instructions }}
          instructions: {},
{{- end }}
        },
        bes: {
{{- if .Values.portal.frontend.featureFlags.bes.pageBuilds }}
          pageBuilds: {},
{{- end }}
{{- if .Values.portal.frontend.featureFlags.bes.pageInvocations }}
          pageInvocations: {},
{{- end }}
{{- if .Values.portal.frontend.featureFlags.bes.pageTargets }}
          pageTargets: {},
{{- end }}
{{- if .Values.portal.frontend.featureFlags.bes.pageTests }}
          pageTests: {},
{{- end }}
{{- if .Values.portal.frontend.featureFlags.bes.pageTrends }}
          pageTrends: {},
{{- end }}
        },
{{- if .Values.portal.frontend.featureFlags.browser }}
        browser: {},
{{- end }}
{{- if .Values.portal.frontend.featureFlags.scheduler }}
        scheduler: {},
{{- end }}
      },
      footerContent: {{ toJson .Values.portal.frontend.footerContent }},
      additionalBuildColumns: {{ toJson .Values.portal.frontend.additionalBuildColumns }},
      additionalBuildInvocationColumns: {{ toJson .Values.portal.frontend.additionalBuildInvocationColumns }},
    },
  },
}
