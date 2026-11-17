local common = import 'common.libsonnet';

{
  // bb-browser is a pre-CDC binary. Dial the frontend for CAS reads so the
  // frontend reassembles multi-chunk blobs across storage shards on the
  // browser's behalf (via ByteStream / BatchReadBlobs).
  blobstore: {
    contentAddressableStorage: {
      grpc: {
        client: {
          address: '{{ if .Values.frontend.internalService.enabled }}{{ .Values.frontend.internalService.name }}{{ else }}frontend-grpc{{ end }}:8980',
        },
      },
    },
    actionCache: common.blobstore.actionCache,
  },
  maximumMessageSizeBytes: common.maximumMessageSizeBytes,
  httpServers: [{
    listenAddresses: [':7984'],
    authenticationPolicy: { allow: {} },
  }],
  global: common.global,
  authorizer: { allow: {} },
  requestMetadataLinksJmespathExpression: { expression: '`{}`' },
}
