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
        {{- if .Values.security.grpcMtls.enabled }}
        {{ include "buildbarn.mtlsClientTls" . | indent 8 | trim }}
        {{- end }}
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
    {{- /* The read cache nests INSIDE the existence cache when both are on.
         ReadCachingBlobAccess overrides only Get and GetFromComposite and
         embeds the slow backend for everything else, so FindMissingBlobs —
         the most frequent CAS call a Bazel client makes, before every upload —
         still crosses to the shards. existenceCaching has to sit above it to
         keep those local.

         The fast tier itself is rendered by buildbarn.frontendReadCachingBackend
         in _helpers.tpl. Its sizing is coupled in two directions that nothing
         validates: blocksSizeGi divided by the block counts must exceed the
         largest blob the frontend moves (a bigger blob fails the build, it does
         not just miss), and keyLocationMapInMemoryEntries must scale with
         blocksSizeGi or the map caps the cache below its disk. See the README's
         "Frontend Read Cache" section.  */}}
    {{- $readCache := .Values.frontend.readCache.enabled }}
    {{- $existenceCache := .Values.frontend.contentAddressableStorage.existenceCaching.enabled }}
    {{- if and $readCache $existenceCache }}
    backend: {
      existenceCaching: {
        existenceCache: {
          cacheSize: {{ int64 .Values.frontend.contentAddressableStorage.existenceCaching.cacheSize }},
          cacheDuration: {{ .Values.frontend.contentAddressableStorage.existenceCaching.cacheDuration | quote }},
          cacheReplacementPolicy: 'LEAST_RECENTLY_USED',
        },
        backend: {{ include "buildbarn.frontendReadCachingBackend" . | indent 8 | trim }},
      },
    },
    {{- else if $readCache }}
    backend: {{ include "buildbarn.frontendReadCachingBackend" . | indent 4 | trim }},
    {{- else if $existenceCache }}
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
