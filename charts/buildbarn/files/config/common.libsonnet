{{- $namespace := include "buildbarn.namespace" . }}
{{- $are := .Values.config.actionCache.actionResultExpiring }}
// Only return ActionResult messages for which all output files are still present
// in the Content Addressable Storage (CAS). Bazel requires this decorator, and it
// is what keeps an Action Cache hit from ever pointing at evicted CAS blobs.
local completenessCheckedActionCache = {
  completenessChecking: {
    backend: {
      sharding: {
        shards: {
{{- range $i, $_ := until (int .Values.storage.replicas) }}
          "{{ $i }}": {
            backend: { grpc: { client: { address: 'storage-{{ $i }}.storage.{{ $namespace }}:8981' } } },
            weight: 1,
          },
{{- end }}
        },
      },
    },
    maximumTotalTreeSizeBytes: 256 * 1024 * 1024,
  },
};

{
  blobstore: {
    contentAddressableStorage: {
      sharding: {
        shards: {
{{- range $i, $_ := until (int .Values.storage.replicas) }}
          "{{ $i }}": {
            backend: { grpc: { client: { address: 'storage-{{ $i }}.storage.{{ $namespace }}:8981' } } },
            weight: 1,
          },
{{- end }}
        },
      },
    },
{{- if $are.enabled }}
    // Hide ActionResults whose worker_completed_timestamp is older than
    // minimumValidity plus a jitter derived from that same timestamp, so every
    // target is rebuilt periodically. This is a FRESHNESS knob: correctness still comes
    // from completenessChecking underneath.
    actionCache: {
      actionResultExpiring: {
        minimumValidity: {{ $are.minimumValidity | quote }},
        maximumValidityJitter: {{ $are.maximumValidityJitter | quote }},
        // ALWAYS emitted. bb-storage calls CheckValid() on this field
        // unconditionally, so omitting it fails startup with
        // "Invalid minimum timestamp: proto: invalid nil Timestamp" — it is a
        // required field despite reading as optional in the proto.
        // The Unix epoch is the identity value: every ActionResult carrying a
        // real worker_completed_timestamp clears it, leaving minimumValidity as
        // the only constraint. Set config.actionCache.actionResultExpiring
        // .minimumTimestamp to flush the Action Cache.
        minimumTimestamp: {{ default "1970-01-01T00:00:00Z" $are.minimumTimestamp | quote }},
        backend: completenessCheckedActionCache,
      },
    },
{{- else }}
    actionCache: completenessCheckedActionCache,
{{- end }}
  },

  # ISCC and FSAC are NOT part of blobstore.BlobstoreConfiguration (which only
  # has CAS + AC). They are separate top-level stores consumed by bb-scheduler
  # (ISCC) and bb-worker (FSAC), so they live as their own common keys rather
  # than inside `blobstore` — otherwise configs that splat the whole
  # `common.blobstore` (e.g. browser.jsonnet) fail with "unknown field".
{{- if .Values.storage.persistence.iscc.enabled }}
  initialSizeClassCache: {
    sharding: {
      shards: {
{{- range $i, $_ := until (int .Values.storage.replicas) }}
        "{{ $i }}": {
          backend: { grpc: { client: { address: 'storage-{{ $i }}.storage.{{ include "buildbarn.namespace" $ }}:8981' } } },
          weight: 1,
        },
{{- end }}
      },
    },
  },
{{- end }}
{{- if .Values.storage.persistence.fsac.enabled }}
  fileSystemAccessCache: {
    sharding: {
      shards: {
{{- range $i, $_ := until (int .Values.storage.replicas) }}
        "{{ $i }}": {
          backend: { grpc: { client: { address: 'storage-{{ $i }}.storage.{{ include "buildbarn.namespace" $ }}:8981' } } },
          weight: 1,
        },
{{- end }}
      },
    },
  },
{{- end }}

  browserUrl: 'https://{{ include "buildbarn.browserHost" . }}',
  maximumMessageSizeBytes: {{ int64 .Values.config.maximumMessageSizeBytes }},
  global: {
    {{- if .Values.tracing.enabled }}
    tracing: {
      backends: [{
        otlpSpanExporter: {
          {{- if .Values.tracing.nodeLocal.enabled }}
          address: std.format('%s:{{ .Values.tracing.nodeLocal.port }}', std.extVar('K8S_LOCAL_NODE_IP')),
          {{- else }}
          address: {{ required "tracing.endpoint is required when tracing.enabled=true and tracing.nodeLocal.enabled=false" .Values.tracing.endpoint | quote }},
          {{- end }}
          {{- if .Values.tracing.tls.enabled }}
          tls: {
            serverName: {{ default .Values.hosts.otel .Values.tracing.tls.serverName | quote }},
            {{- if .Values.tracing.tls.clientCertificate.enabled }}
            clientKeyPair: {
              files: {
                certificatePath: '{{ .Values.tracing.tls.clientCertificate.mountPath }}/{{ .Values.tracing.tls.clientCertificate.certificatePath }}',
                privateKeyPath: '{{ .Values.tracing.tls.clientCertificate.mountPath }}/{{ .Values.tracing.tls.clientCertificate.privateKeyPath }}',
                refreshInterval: {{ .Values.tracing.tls.clientCertificate.refreshInterval | quote }},
              },
            },
            {{- end }}
          },
          {{- end }}
        },
        batchSpanProcessor: {
          batchTimeout: {{ .Values.tracing.batchSpanProcessor.batchTimeout | quote }},
          exportTimeout: {{ .Values.tracing.batchSpanProcessor.exportTimeout | quote }},
          maxExportBatchSize: {{ .Values.tracing.batchSpanProcessor.maxExportBatchSize }},
          maxQueueSize: {{ .Values.tracing.batchSpanProcessor.maxQueueSize }},
        },
      }],
      resourceAttributes: [
        { key: 'service.namespace', value: { stringValue: '{{ include "buildbarn.namespace" . }}' } },
        { key: 'service.name', value: { stringValue: std.extVar('SERVICE_NAME') } },
      ],
      sampler: {
        parentBased: {
          noParent: {
            maximumRate: {
              samplesPerEpoch: {{ .Values.tracing.sampler.parentBasedMaximumRate.samplesPerEpoch }},
              epochDuration: {{ .Values.tracing.sampler.parentBasedMaximumRate.epochDuration | quote }},
            },
          },
          localParentSampled: { always: {} },
          remoteParentSampled: { always: {} },
          localParentNotSampled: { never: {} },
          remoteParentNotSampled: { never: {} },
        },
      },
    },
    {{- end }}
    diagnosticsHttpServer: {
      httpServers: [{
        listenAddresses: [':9980'],
        authenticationPolicy: { allow: {} },
      }],
      enablePrometheus: true,
      enablePprof: true,
      enableActiveSpans: true,
    },
  },
}
