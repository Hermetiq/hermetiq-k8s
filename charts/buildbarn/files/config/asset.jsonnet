local common = import 'common.libsonnet';

{
  contentAddressableStorage: common.blobstore.contentAddressableStorage,
  assetCache: {
    actionCache: common.blobstore.actionCache,
  },
  fetcher: {
    {{- if .Values.remoteAsset.fetcher.http.enabled }}
    http: {},
    {{- end }}
  },
  global: common.global,
  grpcServers: [{
    listenAddresses: [':{{ .Values.remoteAsset.port }}'],
    authenticationPolicy: { allow: {} },
    {{- if .Values.remoteAsset.tracingAttributes.fetchBlobUris.enabled }}
    tracing: {
      '/build.bazel.remote.asset.v1.Fetch/FetchBlob': {
        attributesFromFirstRequestMessage: ['uris'],
      },
    },
    {{- end }}
  }],
  allowUpdatesForInstances: {{ .Values.remoteAsset.allowUpdatesForInstances | toJson }},
  maximumMessageSizeBytes: common.maximumMessageSizeBytes,
  fetchAuthorizer: { allow: {} },
  pushAuthorizer: { allow: {} },
}
