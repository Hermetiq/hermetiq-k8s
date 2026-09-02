local common = import 'common.libsonnet';

{
  contentAddressableStorage: {
    backend: {
      'local': {
        {{- if eq .Values.storage.persistence.cas.backend "blockDevice" }}
        {{- if eq .Values.storage.persistence.cas.blockDevice.keyLocationMap "file" }}
        keyLocationMapOnBlockDevice: {
          file: {
            path: '/storage-cas-meta/cas-keys.db',
            sizeBytes: {{ .Values.storage.persistence.cas.blockDevice.metadata.keyLocationMapSizeMi }} * 1024 * 1024,
          },
        },
        {{- else }}
        keyLocationMapInMemory: {
          entries: {{ int64 .Values.storage.persistence.cas.blockDevice.keyLocationMapInMemoryEntries }},
        },
        {{- end }}
        {{- else }}
        keyLocationMapOnBlockDevice: {
          file: {
            path: '/storage-cas/cas-keys.db',
            sizeBytes: {{ .Values.storage.persistence.cas.keyLocationMapSizeMi }} * 1024 * 1024,
          },
        },
        {{- end }}
        keyLocationMapMaximumGetAttempts: 16,
        keyLocationMapMaximumPutAttempts: 64,
        oldBlocks: {{ .Values.storage.persistence.cas.oldBlocks }},
        currentBlocks: {{ .Values.storage.persistence.cas.currentBlocks }},
        newBlocks: {{ .Values.storage.persistence.cas.newBlocks }},
        blocksOnBlockDevice: {
          source: {
            {{- if eq .Values.storage.persistence.cas.backend "blockDevice" }}
            devicePath: '/dev/bb/cas',
            {{- else }}
            file: {
              path: '/storage-cas/cas-blocks.db',
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
          {{- if .Values.storage.dataIntegrityValidationCache.enabled }}
          dataIntegrityValidationCache: {
            cacheSize: {{ .Values.storage.dataIntegrityValidationCache.cacheSize }},
            cacheDuration: {{ .Values.storage.dataIntegrityValidationCache.cacheDuration | quote }},
            cacheReplacementPolicy: {{ .Values.storage.dataIntegrityValidationCache.cacheReplacementPolicy | quote }},
          },
          {{- end }}
        },
        {{- if not (and (eq .Values.storage.persistence.cas.backend "blockDevice") (ne .Values.storage.persistence.cas.blockDevice.keyLocationMap "file")) }}
        persistent: {
          {{- if eq .Values.storage.persistence.cas.backend "blockDevice" }}
          stateDirectoryPath: '/storage-cas-meta/persistent_state',
          {{- else }}
          stateDirectoryPath: '/storage-cas/persistent_state',
          {{- end }}
          minimumEpochInterval: '300s',
        },
        {{- end }}
      },
    },
    getAuthorizer: { allow: {} },
    putAuthorizer: { allow: {} },
    findMissingAuthorizer: { allow: {} },
  },

  actionCache: {
    backend: {
      'local': {
        {{- if eq .Values.storage.persistence.ac.backend "blockDevice" }}
        {{- if eq .Values.storage.persistence.ac.blockDevice.keyLocationMap "file" }}
        keyLocationMapOnBlockDevice: {
          file: {
            path: '/storage-ac-meta/ac-keys.db',
            sizeBytes: {{ .Values.storage.persistence.ac.blockDevice.metadata.keyLocationMapSizeMi }} * 1024 * 1024,
          },
        },
        {{- else }}
        keyLocationMapInMemory: {
          entries: {{ int64 .Values.storage.persistence.ac.blockDevice.keyLocationMapInMemoryEntries }},
        },
        {{- end }}
        {{- else if eq .Values.storage.persistence.ac.keyLocationMap.type "blockDevice" }}
        keyLocationMapOnBlockDevice: {
          file: {
            path: '/storage-ac/ac-keys.db',
            sizeBytes: {{ .Values.storage.persistence.ac.keyLocationMap.sizeMi }} * 1024 * 1024,
          },
        },
        {{- else }}
        keyLocationMapInMemory: {
          entries: {{ int64 .Values.storage.persistence.ac.keyLocationMap.entries }},
        },
        {{- end }}
        keyLocationMapMaximumGetAttempts: 16,
        keyLocationMapMaximumPutAttempts: 64,
        oldBlocks: {{ .Values.storage.persistence.ac.oldBlocks }},
        currentBlocks: {{ .Values.storage.persistence.ac.currentBlocks }},
        newBlocks: {{ .Values.storage.persistence.ac.newBlocks }},
        blocksOnBlockDevice: {
          source: {
            {{- if eq .Values.storage.persistence.ac.backend "blockDevice" }}
            devicePath: '/dev/bb/ac',
            {{- else }}
            file: {
              path: '/storage-ac/ac-blocks.db',
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
          {{- if .Values.storage.dataIntegrityValidationCache.enabled }}
          dataIntegrityValidationCache: {
            cacheSize: {{ .Values.storage.dataIntegrityValidationCache.cacheSize }},
            cacheDuration: {{ .Values.storage.dataIntegrityValidationCache.cacheDuration | quote }},
            cacheReplacementPolicy: {{ .Values.storage.dataIntegrityValidationCache.cacheReplacementPolicy | quote }},
          },
          {{- end }}
        },
        {{- /* Persistence requires a persistent key-location map: blocks only
             survive a restart if the index referencing them does too. With an
             in-memory KLM, `persistent` would reattach blocks full of
             unreachable data and pay fsync overhead for nothing. */}}
        {{- if or (and (eq .Values.storage.persistence.ac.backend "blockDevice") (eq .Values.storage.persistence.ac.blockDevice.keyLocationMap "file")) (and (ne .Values.storage.persistence.ac.backend "blockDevice") (eq .Values.storage.persistence.ac.keyLocationMap.type "blockDevice")) }}
        persistent: {
          {{- if eq .Values.storage.persistence.ac.backend "blockDevice" }}
          stateDirectoryPath: '/storage-ac-meta/persistent_state',
          {{- else }}
          stateDirectoryPath: '/storage-ac/persistent_state',
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
        {{- if eq .Values.storage.persistence.iscc.backend "blockDevice" }}
        {{- if eq .Values.storage.persistence.iscc.blockDevice.keyLocationMap "file" }}
        keyLocationMapOnBlockDevice: {
          file: {
            path: '/storage-iscc-meta/iscc-keys.db',
            sizeBytes: {{ .Values.storage.persistence.iscc.blockDevice.metadata.keyLocationMapSizeMi }} * 1024 * 1024,
          },
        },
        {{- else }}
        keyLocationMapInMemory: {
          entries: {{ int64 .Values.storage.persistence.iscc.blockDevice.keyLocationMapInMemoryEntries }},
        },
        {{- end }}
        {{- else if eq .Values.storage.persistence.iscc.keyLocationMap.type "blockDevice" }}
        keyLocationMapOnBlockDevice: {
          file: {
            path: '/storage-iscc/iscc-keys.db',
            sizeBytes: {{ .Values.storage.persistence.iscc.keyLocationMap.sizeMi }} * 1024 * 1024,
          },
        },
        {{- else }}
        keyLocationMapInMemory: {
          entries: {{ int64 .Values.storage.persistence.iscc.keyLocationMap.entries }},
        },
        {{- end }}
        keyLocationMapMaximumGetAttempts: 16,
        keyLocationMapMaximumPutAttempts: 64,
        oldBlocks: {{ .Values.storage.persistence.iscc.oldBlocks }},
        currentBlocks: {{ .Values.storage.persistence.iscc.currentBlocks }},
        newBlocks: {{ .Values.storage.persistence.iscc.newBlocks }},
        blocksOnBlockDevice: {
          source: {
            {{- if eq .Values.storage.persistence.iscc.backend "blockDevice" }}
            devicePath: '/dev/bb/iscc',
            {{- else }}
            file: {
              path: '/storage-iscc/iscc-blocks.db',
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
          {{- if .Values.storage.dataIntegrityValidationCache.enabled }}
          dataIntegrityValidationCache: {
            cacheSize: {{ .Values.storage.dataIntegrityValidationCache.cacheSize }},
            cacheDuration: {{ .Values.storage.dataIntegrityValidationCache.cacheDuration | quote }},
            cacheReplacementPolicy: {{ .Values.storage.dataIntegrityValidationCache.cacheReplacementPolicy | quote }},
          },
          {{- end }}
        },
        {{- if or (and (eq .Values.storage.persistence.iscc.backend "blockDevice") (eq .Values.storage.persistence.iscc.blockDevice.keyLocationMap "file")) (and (ne .Values.storage.persistence.iscc.backend "blockDevice") (eq .Values.storage.persistence.iscc.keyLocationMap.type "blockDevice")) }}
        persistent: {
          {{- if eq .Values.storage.persistence.iscc.backend "blockDevice" }}
          stateDirectoryPath: '/storage-iscc-meta/persistent_state',
          {{- else }}
          stateDirectoryPath: '/storage-iscc/persistent_state',
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
        {{- if eq .Values.storage.persistence.fsac.backend "blockDevice" }}
        {{- if eq .Values.storage.persistence.fsac.blockDevice.keyLocationMap "file" }}
        keyLocationMapOnBlockDevice: {
          file: {
            path: '/storage-fsac-meta/fsac-keys.db',
            sizeBytes: {{ .Values.storage.persistence.fsac.blockDevice.metadata.keyLocationMapSizeMi }} * 1024 * 1024,
          },
        },
        {{- else }}
        keyLocationMapInMemory: {
          entries: {{ int64 .Values.storage.persistence.fsac.blockDevice.keyLocationMapInMemoryEntries }},
        },
        {{- end }}
        {{- else if eq .Values.storage.persistence.fsac.keyLocationMap.type "blockDevice" }}
        keyLocationMapOnBlockDevice: {
          file: {
            path: '/storage-fsac/fsac-keys.db',
            sizeBytes: {{ .Values.storage.persistence.fsac.keyLocationMap.sizeMi }} * 1024 * 1024,
          },
        },
        {{- else }}
        keyLocationMapInMemory: {
          entries: {{ int64 .Values.storage.persistence.fsac.keyLocationMap.entries }},
        },
        {{- end }}
        keyLocationMapMaximumGetAttempts: 16,
        keyLocationMapMaximumPutAttempts: 64,
        oldBlocks: {{ .Values.storage.persistence.fsac.oldBlocks }},
        currentBlocks: {{ .Values.storage.persistence.fsac.currentBlocks }},
        newBlocks: {{ .Values.storage.persistence.fsac.newBlocks }},
        blocksOnBlockDevice: {
          source: {
            {{- if eq .Values.storage.persistence.fsac.backend "blockDevice" }}
            devicePath: '/dev/bb/fsac',
            {{- else }}
            file: {
              path: '/storage-fsac/fsac-blocks.db',
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
          {{- if .Values.storage.dataIntegrityValidationCache.enabled }}
          dataIntegrityValidationCache: {
            cacheSize: {{ .Values.storage.dataIntegrityValidationCache.cacheSize }},
            cacheDuration: {{ .Values.storage.dataIntegrityValidationCache.cacheDuration | quote }},
            cacheReplacementPolicy: {{ .Values.storage.dataIntegrityValidationCache.cacheReplacementPolicy | quote }},
          },
          {{- end }}
        },
        {{- if or (and (eq .Values.storage.persistence.fsac.backend "blockDevice") (eq .Values.storage.persistence.fsac.blockDevice.keyLocationMap "file")) (and (ne .Values.storage.persistence.fsac.backend "blockDevice") (eq .Values.storage.persistence.fsac.keyLocationMap.type "blockDevice")) }}
        persistent: {
          {{- if eq .Values.storage.persistence.fsac.backend "blockDevice" }}
          stateDirectoryPath: '/storage-fsac-meta/persistent_state',
          {{- else }}
          stateDirectoryPath: '/storage-fsac/persistent_state',
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
    authenticationPolicy: {
      allow: {},
    },
  }],
}
