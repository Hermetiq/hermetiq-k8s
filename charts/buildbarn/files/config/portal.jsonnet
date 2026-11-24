local common = import 'common.libsonnet';

{
  global: common.global,
  maximumMessageSizeBytes: common.maximumMessageSizeBytes,
  httpServers: [{
    listenAddresses: [':8081'],
    authenticationPolicy: { allow: {} },
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
    cleanupConfiguration: {
      cleanupInterval: '{{ .Values.portal.bes.cleanup.cleanupInterval }}',
      invocationMessageTimeout: '{{ .Values.portal.bes.cleanup.invocationMessageTimeout }}',
      invocationRetention: '{{ .Values.portal.bes.cleanup.invocationRetention }}',
    },
  },

  besServiceConfiguration: {
    grpcServers: [{
      listenAddresses: [':8082'],
      authenticationPolicy: { allow: {} },
      // Individual build events are small; this is independent of the shared
      // common.maximumMessageSizeBytes used for blob traffic.
      maximumReceivedMessageSizeBytes: 10 * 1024 * 1024,
    }],
    enableBepFileUpload: {{ .Values.portal.bes.enableBepFileUpload }},
    saveDataLevel: { basicAndTarget: {} },
    minEventBatchDuration: '{{ .Values.portal.bes.minEventBatchDuration }}',
{{- with .Values.portal.bes.buildKey }}
    buildKey: {{ . | quote }},
{{- end }}
{{- with .Values.portal.bes.invocationMetadataExtractor }}
    // Populates username/hostname/sourceControls/invocationTags/buildTags from
    // Bazel's environment. buildKey above reads from the buildTags it returns.
    invocationMetadataExtractor: {{ toJson . }},
{{- end }}
    publishAuthorizer: { allow: {} },
  },

  graphqlApiServiceConfiguration: {
    readAuthorizer: { allow: {} },
  },

  // Blob browsing reads the storage shards directly via the shared CDC CAS
  // configuration. ISCC/FSAC views light up only when those stores are enabled
  // in common.libsonnet.
  contentAddressableStorageServer: {
    contentAddressableStorage: common.blobstore.contentAddressableStorage,
    readAuthorizer: { allow: {} },
  },
  actionCache: {
    backend: common.blobstore.actionCache,
    readAuthorizer: { allow: {} },
  },
  [if std.objectHas(common, 'initialSizeClassCache') then 'initialSizeClassCache']: {
    backend: common.initialSizeClassCache,
    readAuthorizer: { allow: {} },
  },
  [if std.objectHas(common, 'fileSystemAccessCache') then 'fileSystemAccessCache']: {
    backend: common.fileSystemAccessCache,
    readAuthorizer: { allow: {} },
  },
  blobstoreServiceConfiguration: {},

  schedulerServiceConfiguration: {
    buildQueueStateClient: {
      address: 'scheduler:8984',
      {{- if .Values.security.grpcMtls.enabled }}
      {{ include "buildbarn.mtlsClientTls" . | indent 6 | trim }}
      {{- end }}
    },
    killOperationsAuthorizer: {
      allow: {},
    },
    readAuthorizer: {
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
