local common = import 'common.libsonnet';

{
  contentAddressableStorageServer: {
    contentAddressableStorage: {
      chunkStorage: {
        'local': {
          keyLocationMap: {
            {{- if eq .Values.storage.persistence.cas.backend "blockDevice" }}
            {{- if eq .Values.storage.persistence.cas.blockDevice.keyLocationMap "file" }}
            onBlockDevice: {
              file: {
                path: '/storage-cas-meta/cdc-v1/keys.db',
                sizeBytes: {{ .Values.storage.persistence.cas.blockDevice.metadata.keyLocationMapSizeMi }} * 1024 * 1024,
              },
            },
            {{- else }}
            inMemory: {
              entries: {{ int64 .Values.storage.persistence.cas.blockDevice.keyLocationMapInMemoryEntries }},
            },
            {{- end }}
            {{- else }}
            onBlockDevice: {
              file: {
                path: '/storage-cas/cdc-v1/keys.db',
                sizeBytes: {{ .Values.storage.persistence.cas.keyLocationMapSizeMi }} * 1024 * 1024,
              },
            },
            {{- end }}
            maximumGetAttempts: 16,
            maximumPutAttempts: 64,
          },
          oldBlocks: {{ .Values.storage.persistence.cas.oldBlocks }},
          currentBlocks: {{ .Values.storage.persistence.cas.currentBlocks }},
          newBlocks: {{ .Values.storage.persistence.cas.newBlocks }},
          blocksOnBlockDevice: {
            source: {
              {{- if eq .Values.storage.persistence.cas.backend "blockDevice" }}
              devicePath: '/dev/bb/cas',
              {{- else }}
              file: {
                path: '/storage-cas/cdc-v1/blocks.db',
                sizeBytes: {{ .Values.storage.persistence.cas.blocksSizeGi }} * 1024 * 1024 * 1024,
              },
              {{- end }}
              {{- /* writeConcurrencyLimit is a field of blockdevice.Configuration,
                   so it must sit inside `source` next to devicePath/file. */}}
              {{- $casWcl := .Values.storage.persistence.cas.writeConcurrencyLimit }}
              {{- if and (not $casWcl) (eq .Values.storage.persistence.cas.backend "blockDevice") }}
              {{- $casWcl = .Values.storage.persistence.cas.blockDevice.writeConcurrencyLimit }}
              {{- end }}
              {{- if $casWcl }}
              writeConcurrencyLimit: {{ $casWcl }},
              {{- end }}
            },
            spareBlocks: {{ .Values.storage.persistence.cas.spareBlocks }},
          },
          {{- if not (and (eq .Values.storage.persistence.cas.backend "blockDevice") (ne .Values.storage.persistence.cas.blockDevice.keyLocationMap "file")) }}
          persistent: {
            {{- if eq .Values.storage.persistence.cas.backend "blockDevice" }}
            stateDirectoryPath: '/storage-cas-meta/cdc-v1/persistent_state',
            {{- else }}
            stateDirectoryPath: '/storage-cas/cdc-v1/persistent_state',
            {{- end }}
            minimumEpochInterval: '300s',
          },
          {{- end }}
          chunkingParameters: {
            minChunkSizeBytes: {{ int64 .Values.config.contentAddressableStorage.chunkingParameters.minChunkSizeBytes }},
            horizonSizeBytes: {{ int64 .Values.config.contentAddressableStorage.chunkingParameters.horizonSizeBytes }},
          },
        },
      },
      {{- $cms := .Values.storage.persistence.cms }}
      {{- $casNoFs := and (eq .Values.storage.persistence.cas.backend "blockDevice") (ne .Values.storage.persistence.cas.blockDevice.keyLocationMap "file") }}
      {{- $sharedCasDir := ternary "/storage-cas-meta" "/storage-cas" (eq .Values.storage.persistence.cas.backend "blockDevice") }}
      chunkMappingStorage: {
        'local': {
          keyLocationMap: {
            {{- if eq $cms.backend "blockDevice" }}
            {{- if eq $cms.blockDevice.keyLocationMap "file" }}
            onBlockDevice: {
              file: {
                path: '/storage-cms-meta/cms-keys.db',
                sizeBytes: {{ $cms.blockDevice.metadata.keyLocationMapSizeMi }} * 1024 * 1024,
              },
            },
            {{- else }}
            inMemory: {
              entries: {{ int64 $cms.blockDevice.keyLocationMapInMemoryEntries }},
            },
            {{- end }}
            {{- else if and (eq $cms.backend "sharedCas") (not $casNoFs) (eq $cms.keyLocationMap.type "blockDevice") }}
            onBlockDevice: {
              file: {
                path: '{{ $sharedCasDir }}/cdc-v1/cms-keys.db',
                sizeBytes: {{ $cms.keyLocationMap.sizeMi }} * 1024 * 1024,
              },
            },
            {{- else if and (eq $cms.backend "filesystem") (eq $cms.keyLocationMap.type "blockDevice") }}
            onBlockDevice: {
              file: {
                path: '/storage-cms/cms-keys.db',
                sizeBytes: {{ $cms.keyLocationMap.sizeMi }} * 1024 * 1024,
              },
            },
            {{- else }}
            inMemory: {
              entries: {{ int64 $cms.keyLocationMap.entries }},
            },
            {{- end }}
            maximumGetAttempts: 16,
            maximumPutAttempts: 64,
          },
          oldBlocks: {{ $cms.oldBlocks }},
          currentBlocks: {{ $cms.currentBlocks }},
          newBlocks: {{ $cms.newBlocks }},
          {{- if and (eq $cms.backend "sharedCas") $casNoFs }}
          blocksInMemory: {
            blockSizeBytes: {{ int64 $cms.blocksInMemoryBlockSizeBytes }},
          },
          {{- else }}
          blocksOnBlockDevice: {
            source: {
              {{- if eq $cms.backend "blockDevice" }}
              devicePath: '/dev/bb/cms',
              {{- else if eq $cms.backend "sharedCas" }}
              file: {
                path: '{{ $sharedCasDir }}/cdc-v1/cms-blocks.db',
                sizeBytes: {{ $cms.blocksSizeGi }} * 1024 * 1024 * 1024,
              },
              {{- else }}
              file: {
                path: '/storage-cms/cms-blocks.db',
                sizeBytes: {{ $cms.blocksSizeGi }} * 1024 * 1024 * 1024,
              },
              {{- end }}
              {{- $cmsWcl := $cms.writeConcurrencyLimit }}
              {{- if and (not $cmsWcl) (eq $cms.backend "blockDevice") }}
              {{- $cmsWcl = $cms.blockDevice.writeConcurrencyLimit }}
              {{- end }}
              {{- if $cmsWcl }}
              writeConcurrencyLimit: {{ $cmsWcl }},
              {{- end }}
            },
            spareBlocks: {{ $cms.spareBlocks }},
          },
          {{- end }}
          {{- if or (and (eq $cms.backend "blockDevice") (eq $cms.blockDevice.keyLocationMap "file")) (and (eq $cms.backend "filesystem") (eq $cms.keyLocationMap.type "blockDevice")) (and (eq $cms.backend "sharedCas") (not $casNoFs) (eq $cms.keyLocationMap.type "blockDevice")) }}
          persistent: {
            {{- if eq $cms.backend "blockDevice" }}
            stateDirectoryPath: '/storage-cms-meta/persistent_state',
            {{- else if eq $cms.backend "sharedCas" }}
            stateDirectoryPath: '{{ $sharedCasDir }}/cdc-v1/cms_persistent_state',
            {{- else }}
            stateDirectoryPath: '/storage-cms/persistent_state',
            {{- end }}
            minimumEpochInterval: '300s',
          },
          {{- end }}
        },
      },
    },
    getAuthorizer: { allow: {} },
    putAuthorizer: { allow: {} },
    findMissingAuthorizer: { allow: {} },
    maximumChunkCount: {{ int64 .Values.config.contentAddressableStorage.maximumChunkCount }},
  },

  actionCache: {
    backend: {
      'local': {
        keyLocationMap: {
          {{- if eq .Values.storage.persistence.ac.backend "blockDevice" }}
          {{- if eq .Values.storage.persistence.ac.blockDevice.keyLocationMap "file" }}
          onBlockDevice: {
            file: {
              path: '/storage-ac-meta/cdc-v1/ac-keys.db',
              sizeBytes: {{ .Values.storage.persistence.ac.blockDevice.metadata.keyLocationMapSizeMi }} * 1024 * 1024,
            },
          },
          {{- else }}
          inMemory: {
            entries: {{ int64 .Values.storage.persistence.ac.blockDevice.keyLocationMapInMemoryEntries }},
          },
          {{- end }}
          {{- else if eq .Values.storage.persistence.ac.keyLocationMap.type "blockDevice" }}
          onBlockDevice: {
            file: {
              path: '/storage-ac/cdc-v1/ac-keys.db',
              sizeBytes: {{ .Values.storage.persistence.ac.keyLocationMap.sizeMi }} * 1024 * 1024,
            },
          },
          {{- else }}
          inMemory: {
            entries: {{ int64 .Values.storage.persistence.ac.keyLocationMap.entries }},
          },
          {{- end }}
          maximumGetAttempts: 16,
          maximumPutAttempts: 64,
        },
        oldBlocks: {{ .Values.storage.persistence.ac.oldBlocks }},
        currentBlocks: {{ .Values.storage.persistence.ac.currentBlocks }},
        newBlocks: {{ .Values.storage.persistence.ac.newBlocks }},
        blocksOnBlockDevice: {
          source: {
            {{- if eq .Values.storage.persistence.ac.backend "blockDevice" }}
            devicePath: '/dev/bb/ac',
            {{- else }}
            file: {
              path: '/storage-ac/cdc-v1/ac-blocks.db',
              sizeBytes: {{ .Values.storage.persistence.ac.blocksSizeGi }} * 1024 * 1024 * 1024,
            },
            {{- end }}
            {{- $acWcl := .Values.storage.persistence.ac.writeConcurrencyLimit }}
            {{- if and (not $acWcl) (eq .Values.storage.persistence.ac.backend "blockDevice") }}
            {{- $acWcl = .Values.storage.persistence.ac.blockDevice.writeConcurrencyLimit }}
            {{- end }}
            {{- if $acWcl }}
            writeConcurrencyLimit: {{ $acWcl }},
            {{- end }}
          },
          spareBlocks: {{ .Values.storage.persistence.ac.spareBlocks }},
        },
        {{- /* Persistence requires a persistent key-location map: blocks only
             survive a restart if the index referencing them does too. With an
             in-memory KLM, `persistent` would reattach blocks full of
             unreachable data and pay fsync overhead for nothing. */}}
        {{- if or (and (eq .Values.storage.persistence.ac.backend "blockDevice") (eq .Values.storage.persistence.ac.blockDevice.keyLocationMap "file")) (and (ne .Values.storage.persistence.ac.backend "blockDevice") (eq .Values.storage.persistence.ac.keyLocationMap.type "blockDevice")) }}
        persistent: {
          {{- if eq .Values.storage.persistence.ac.backend "blockDevice" }}
          stateDirectoryPath: '/storage-ac-meta/cdc-v1/persistent_state',
          {{- else }}
          stateDirectoryPath: '/storage-ac/cdc-v1/persistent_state',
          {{- end }}
          minimumEpochInterval: '300s',
        },
        {{- end }}
      },
    },
    getAuthorizer: { allow: {} },
    putAuthorizer: { allow: {} },
  },
{{- if .Values.storage.persistence.iscc.enabled }}

  initialSizeClassCache: {
    backend: {
      'local': {
        keyLocationMap: {
          {{- if eq .Values.storage.persistence.iscc.backend "blockDevice" }}
          {{- if eq .Values.storage.persistence.iscc.blockDevice.keyLocationMap "file" }}
          onBlockDevice: {
            file: {
              path: '/storage-iscc-meta/cdc-v1/iscc-keys.db',
              sizeBytes: {{ .Values.storage.persistence.iscc.blockDevice.metadata.keyLocationMapSizeMi }} * 1024 * 1024,
            },
          },
          {{- else }}
          inMemory: {
            entries: {{ int64 .Values.storage.persistence.iscc.blockDevice.keyLocationMapInMemoryEntries }},
          },
          {{- end }}
          {{- else if eq .Values.storage.persistence.iscc.keyLocationMap.type "blockDevice" }}
          onBlockDevice: {
            file: {
              path: '/storage-iscc/cdc-v1/iscc-keys.db',
              sizeBytes: {{ .Values.storage.persistence.iscc.keyLocationMap.sizeMi }} * 1024 * 1024,
            },
          },
          {{- else }}
          inMemory: {
            entries: {{ int64 .Values.storage.persistence.iscc.keyLocationMap.entries }},
          },
          {{- end }}
          maximumGetAttempts: 16,
          maximumPutAttempts: 64,
        },
        oldBlocks: {{ .Values.storage.persistence.iscc.oldBlocks }},
        currentBlocks: {{ .Values.storage.persistence.iscc.currentBlocks }},
        newBlocks: {{ .Values.storage.persistence.iscc.newBlocks }},
        blocksOnBlockDevice: {
          source: {
            {{- if eq .Values.storage.persistence.iscc.backend "blockDevice" }}
            devicePath: '/dev/bb/iscc',
            {{- else }}
            file: {
              path: '/storage-iscc/cdc-v1/iscc-blocks.db',
              sizeBytes: {{ .Values.storage.persistence.iscc.blocksSizeGi }} * 1024 * 1024 * 1024,
            },
            {{- end }}
            {{- $isccWcl := .Values.storage.persistence.iscc.writeConcurrencyLimit }}
            {{- if and (not $isccWcl) (eq .Values.storage.persistence.iscc.backend "blockDevice") }}
            {{- $isccWcl = .Values.storage.persistence.iscc.blockDevice.writeConcurrencyLimit }}
            {{- end }}
            {{- if $isccWcl }}
            writeConcurrencyLimit: {{ $isccWcl }},
            {{- end }}
          },
          spareBlocks: {{ .Values.storage.persistence.iscc.spareBlocks }},
        },
        {{- if or (and (eq .Values.storage.persistence.iscc.backend "blockDevice") (eq .Values.storage.persistence.iscc.blockDevice.keyLocationMap "file")) (and (ne .Values.storage.persistence.iscc.backend "blockDevice") (eq .Values.storage.persistence.iscc.keyLocationMap.type "blockDevice")) }}
        persistent: {
          {{- if eq .Values.storage.persistence.iscc.backend "blockDevice" }}
          stateDirectoryPath: '/storage-iscc-meta/cdc-v1/persistent_state',
          {{- else }}
          stateDirectoryPath: '/storage-iscc/cdc-v1/persistent_state',
          {{- end }}
          minimumEpochInterval: '300s',
        },
        {{- end }}
      },
    },
    getAuthorizer: { allow: {} },
    putAuthorizer: { allow: {} },
  },
{{- end }}
{{- if .Values.storage.persistence.fsac.enabled }}

  fileSystemAccessCache: {
    backend: {
      'local': {
        keyLocationMap: {
          {{- if eq .Values.storage.persistence.fsac.backend "blockDevice" }}
          {{- if eq .Values.storage.persistence.fsac.blockDevice.keyLocationMap "file" }}
          onBlockDevice: {
            file: {
              path: '/storage-fsac-meta/cdc-v1/fsac-keys.db',
              sizeBytes: {{ .Values.storage.persistence.fsac.blockDevice.metadata.keyLocationMapSizeMi }} * 1024 * 1024,
            },
          },
          {{- else }}
          inMemory: {
            entries: {{ int64 .Values.storage.persistence.fsac.blockDevice.keyLocationMapInMemoryEntries }},
          },
          {{- end }}
          {{- else if eq .Values.storage.persistence.fsac.keyLocationMap.type "blockDevice" }}
          onBlockDevice: {
            file: {
              path: '/storage-fsac/cdc-v1/fsac-keys.db',
              sizeBytes: {{ .Values.storage.persistence.fsac.keyLocationMap.sizeMi }} * 1024 * 1024,
            },
          },
          {{- else }}
          inMemory: {
            entries: {{ int64 .Values.storage.persistence.fsac.keyLocationMap.entries }},
          },
          {{- end }}
          maximumGetAttempts: 16,
          maximumPutAttempts: 64,
        },
        oldBlocks: {{ .Values.storage.persistence.fsac.oldBlocks }},
        currentBlocks: {{ .Values.storage.persistence.fsac.currentBlocks }},
        newBlocks: {{ .Values.storage.persistence.fsac.newBlocks }},
        blocksOnBlockDevice: {
          source: {
            {{- if eq .Values.storage.persistence.fsac.backend "blockDevice" }}
            devicePath: '/dev/bb/fsac',
            {{- else }}
            file: {
              path: '/storage-fsac/cdc-v1/fsac-blocks.db',
              sizeBytes: {{ .Values.storage.persistence.fsac.blocksSizeGi }} * 1024 * 1024 * 1024,
            },
            {{- end }}
            {{- $fsacWcl := .Values.storage.persistence.fsac.writeConcurrencyLimit }}
            {{- if and (not $fsacWcl) (eq .Values.storage.persistence.fsac.backend "blockDevice") }}
            {{- $fsacWcl = .Values.storage.persistence.fsac.blockDevice.writeConcurrencyLimit }}
            {{- end }}
            {{- if $fsacWcl }}
            writeConcurrencyLimit: {{ $fsacWcl }},
            {{- end }}
          },
          spareBlocks: {{ .Values.storage.persistence.fsac.spareBlocks }},
        },
        {{- if or (and (eq .Values.storage.persistence.fsac.backend "blockDevice") (eq .Values.storage.persistence.fsac.blockDevice.keyLocationMap "file")) (and (ne .Values.storage.persistence.fsac.backend "blockDevice") (eq .Values.storage.persistence.fsac.keyLocationMap.type "blockDevice")) }}
        persistent: {
          {{- if eq .Values.storage.persistence.fsac.backend "blockDevice" }}
          stateDirectoryPath: '/storage-fsac-meta/cdc-v1/persistent_state',
          {{- else }}
          stateDirectoryPath: '/storage-fsac/cdc-v1/persistent_state',
          {{- end }}
          minimumEpochInterval: '300s',
        },
        {{- end }}
      },
    },
    getAuthorizer: { allow: {} },
    putAuthorizer: { allow: {} },
  },
{{- end }}

  maximumMessageSizeBytes: common.maximumMessageSizeBytes,

  global: common.global,

  grpcServers: [{
    listenAddresses: [':8981'],
    {{- if .Values.security.grpcMtls.enabled }}
    {{ include "buildbarn.mtlsServerTls" . | indent 4 | trim }}
    {{- end }}
    {{ include "buildbarn.authenticationPolicy" (dict "root" $ "config" .Values.storage.grpcServers.authenticationPolicy "path" "storage.grpcServers.authenticationPolicy") | indent 4 | trim }}
  }],
}
