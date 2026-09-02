local common = import 'common.libsonnet';

{
  grpcServers: [{
    listenAddresses: [':8980'],
    {{- if .Values.frontend.jwks.enabled }}
    authenticationPolicy: {
      any: {
        policies: [
          {
            jwt: {
              jwksFile: '/etc/buildbarn/jwks/{{ .Values.frontend.jwks.configMapKey }}',
              maximumCacheSize: 1000,
              cacheReplacementPolicy: 'LEAST_RECENTLY_USED',
              claimsValidationJmespathExpression: { expression:
                {{- $expr := .Values.frontend.jwks.claimsValidationExpression -}}
                {{- $issuer := .Values.frontend.jwks.issuer -}}
                {{- $audience := .Values.frontend.jwks.audience -}}
                {{- if $expr }}
                {{ $expr | quote }}
                {{- else if and $issuer $audience }}
                {{ printf "payload.iss == '%s' && contains(to_array(payload.aud), '%s')" (replace "'" "\\'" $issuer) (replace "'" "\\'" $audience) | quote }}
                {{- else if $issuer }}
                {{ printf "payload.iss == '%s'" (replace "'" "\\'" $issuer) | quote }}
                {{- else if $audience }}
                {{ printf "contains(to_array(payload.aud), '%s')" (replace "'" "\\'" $audience) | quote }}
                {{- else }}
                '`true`'
                {{- end }}
              },
              metadataExtractionJmespathExpression: { expression: '{ "private": { "canWriteToCache": `true` }}' },
            },
          },
          { allow: {} },
        ],
      },
    },
    {{- else }}
    authenticationPolicy: { allow: {} },
    {{- end }}
    {{- if .Values.frontend.tracingAttributes.actionCacheDigests.enabled }}
    tracing: {
      '/build.bazel.remote.execution.v2.ActionCache/GetActionResult': {
        attributesFromFirstRequestMessage: ['action_digest.hash'],
      },
      '/build.bazel.remote.execution.v2.ActionCache/UpdateActionResult': {
        attributesFromFirstRequestMessage: ['action_digest.hash'],
      },
    },
    {{- end }}
  }],
  schedulers: {
    '': {
      endpoint: {
        address: 'scheduler:8982',
        addMetadataJmespathExpression: {
          expression: |||
            {
              "build.bazel.remote.execution.v2.requestmetadata-bin": incomingGRPCMetadata."build.bazel.remote.execution.v2.requestmetadata-bin"
            }
          |||,
        },
      },
    },
  },
  maximumMessageSizeBytes: common.maximumMessageSizeBytes,

  global: common.global,

  contentAddressableStorage: {
    {{- if .Values.frontend.readCache.enabled }}
    backend: {
      readCaching: {
        slow: common.blobstore.contentAddressableStorage,
        fast: {
          'local': {
            keyLocationMapInMemory: {
              entries: {{ int64 .Values.frontend.readCache.keyLocationMapInMemoryEntries }},
            },
            keyLocationMapMaximumGetAttempts: 16,
            keyLocationMapMaximumPutAttempts: 64,
            oldBlocks: {{ .Values.frontend.readCache.oldBlocks }},
            currentBlocks: {{ .Values.frontend.readCache.currentBlocks }},
            newBlocks: {{ .Values.frontend.readCache.newBlocks }},
            blocksOnBlockDevice: {
              source: {
                file: {
                  path: '{{ .Values.frontend.readCache.mountPath }}/blocks',
                  sizeBytes: {{ .Values.frontend.readCache.blocksSizeGi }} * 1024 * 1024 * 1024,
                },
              },
              spareBlocks: {{ .Values.frontend.readCache.spareBlocks }},
            },
          },
        },
        replicator: { deduplicating: { 'local': {} } },
      },
    },
    {{- else if .Values.frontend.contentAddressableStorage.existenceCaching.enabled }}
    backend: {
      existenceCaching: {
        backend: common.blobstore.contentAddressableStorage,
        existenceCache: {
          cacheSize: {{ int64 .Values.frontend.contentAddressableStorage.existenceCaching.cacheSize }},
          cacheDuration: {{ .Values.frontend.contentAddressableStorage.existenceCaching.cacheDuration | quote }},
          cacheReplacementPolicy: 'LEAST_RECENTLY_USED',
        },
      },
    },
    {{- else }}
    {{- /* No FindMissingBlobs caching: every lookup goes straight to the shards.
         Correct (never stale) but higher storage read load. */}}
    backend: common.blobstore.contentAddressableStorage,
    {{- end }}
    getAuthorizer: { allow: {} },
    putAuthorizer: {
      {{- if eq .Values.frontend.contentAddressableStorage.putAuthorizer.mode "allow" }}
      allow: {},
      {{- else if eq .Values.frontend.contentAddressableStorage.putAuthorizer.mode "deny" }}
      deny: {},
      {{- else if eq .Values.frontend.contentAddressableStorage.putAuthorizer.mode "requireCanWriteToCache" }}
      jmespathExpression: {
        expression: {{ .Values.frontend.contentAddressableStorage.putAuthorizer.requireCanWriteToCacheExpression | quote }},
      },
      {{- else if eq .Values.frontend.contentAddressableStorage.putAuthorizer.mode "custom" }}
{{ required "frontend.contentAddressableStorage.putAuthorizer.custom is required when mode=custom" .Values.frontend.contentAddressableStorage.putAuthorizer.custom | nindent 6 }}
      {{- else }}
      {{- fail "frontend.contentAddressableStorage.putAuthorizer.mode must be one of allow, deny, requireCanWriteToCache, custom" }}
      {{- end }}
    },
    findMissingAuthorizer: { allow: {} },
  },
  actionCache: {
    backend: common.blobstore.actionCache,
    getAuthorizer: { allow: {} },
    putAuthorizer: {
      {{- if eq .Values.frontend.actionCache.putAuthorizer.mode "allow" }}
      allow: {},
      {{- else if eq .Values.frontend.actionCache.putAuthorizer.mode "deny" }}
      deny: {},
      {{- else if eq .Values.frontend.actionCache.putAuthorizer.mode "requireCanWriteToCache" }}
      jmespathExpression: {
        expression: {{ .Values.frontend.actionCache.putAuthorizer.requireCanWriteToCacheExpression | quote }},
      },
      {{- else if eq .Values.frontend.actionCache.putAuthorizer.mode "custom" }}
{{ required "frontend.actionCache.putAuthorizer.custom is required when mode=custom" .Values.frontend.actionCache.putAuthorizer.custom | nindent 6 }}
      {{- else }}
      {{- fail "frontend.actionCache.putAuthorizer.mode must be one of allow, deny, requireCanWriteToCache, custom" }}
      {{- end }}
    },
  },
  executeAuthorizer: {
    {{- if eq .Values.frontend.executeAuthorizer.mode "allow" }}
    allow: {},
    {{- else if eq .Values.frontend.executeAuthorizer.mode "deny" }}
    deny: {},
    {{- else if eq .Values.frontend.executeAuthorizer.mode "requireCanWriteToCache" }}
    jmespathExpression: {
      expression: {{ .Values.frontend.executeAuthorizer.requireCanWriteToCacheExpression | quote }},
    },
    {{- else if eq .Values.frontend.executeAuthorizer.mode "custom" }}
{{ required "frontend.executeAuthorizer.custom is required when mode=custom" .Values.frontend.executeAuthorizer.custom | nindent 4 }}
    {{- else }}
    {{- fail "frontend.executeAuthorizer.mode must be one of allow, deny, requireCanWriteToCache, custom" }}
    {{- end }}
  },
  supportedCompressors: ['ZSTD'],
}
