local common = import 'common.libsonnet';

{
  bbcalAddress: '{{ .Values.bbcal.address }}',

  workerConfig(config, runner):: (
    local nativeBuildDirectory = {
      native: {
        buildDirectoryPath: '/worker/build',
        cacheDirectoryPath: '/worker/cache',
        maximumCacheFileCount: config.nativeBuildDirectory.maximumCacheFileCount,
        maximumCacheSizeBytes: config.nativeBuildDirectory.maximumCacheSizeBytes,
        cacheReplacementPolicy: 'LEAST_RECENTLY_USED',
      },
    };
    local virtualBuildDirectoryConfig = {
      virtual: {
        mount: {
          mountPath: '/worker/build',
          fuse: {
            directoryEntryValidity: config.virtualBuildDirectory.fuse.directoryEntryValidity,
            inodeAttributeValidity: config.virtualBuildDirectory.fuse.inodeAttributeValidity,
            allowOther: config.virtualBuildDirectory.fuse.allowOther,
            mountMethod: config.virtualBuildDirectory.fuse.mountMethod,
          },
        },
        maximumExecutionTimeoutCompensation: config.virtualBuildDirectory.maximumExecutionTimeoutCompensation,
        maximumWritableFileUploadDelay: config.virtualBuildDirectory.maximumWritableFileUploadDelay,
        shuffleDirectoryListings: config.virtualBuildDirectory.shuffleDirectoryListings,
      },
    };
    local useVirtual = config.virtualBuildDirectory.enabled;
    local filePoolConfig = if !useVirtual then {} else {
      filePool: {
        blockDevice: {
          file: {
            path: config.virtualBuildDirectory.filePoolPath,
            sizeBytes: config.virtualBuildDirectory.filePoolSizeBytes,
          },
        },
      },
    };
    local dataIntegrityValidationCache = (
      if !config.contentAddressableStorageReadCache.dataIntegrityValidationCache.enabled then {} else {
        dataIntegrityValidationCache: {
          cacheSize: config.contentAddressableStorageReadCache.dataIntegrityValidationCache.cacheSize,
          cacheDuration: config.contentAddressableStorageReadCache.dataIntegrityValidationCache.cacheDuration,
          cacheReplacementPolicy: config.contentAddressableStorageReadCache.dataIntegrityValidationCache.cacheReplacementPolicy,
        },
      }
    );
    local virtualRunnerExtras = if !useVirtual then {} else {
      maximumFilePoolFileCount: config.virtualBuildDirectory.maximumFilePoolFileCount,
      maximumFilePoolSizeBytes: config.virtualBuildDirectory.maximumFilePoolSizeBytes,
    };
    local completedActionLoggers = (
      if !config.completedActionLoggers.enabled then {} else {
        completedActionLoggers: [{
          client: {
            address: $.bbcalAddress,
          },
          maximumSendQueueSize: config.completedActionLoggers.maximumSendQueueSize,
        }],
      }
    );
    local prefetchingConfig = (
      if !config.prefetching.enabled then {} else {
        prefetching: {
          fileSystemAccessCache: common.fileSystemAccessCache,
          bloomFilterBitsPerPath: config.prefetching.bloomFilterBitsPerPath,
          bloomFilterMaximumSizeBytes: config.prefetching.bloomFilterMaximumSizeBytes,
        },
      }
    );
    {
      blobstore: {
        actionCache: common.blobstore.actionCache,
        contentAddressableStorage: {
          readCaching: {
            slow: common.blobstore.contentAddressableStorage,
            fast: {
              'local': {
                keyLocationMapOnBlockDevice: {
                  file: {
                    path: '/storage-worker-cas/key_location_map',
                    sizeBytes: config.contentAddressableStorageReadCache.keyLocationMapSizeBytes,
                  },
                },
                keyLocationMapMaximumGetAttempts: config.contentAddressableStorageReadCache.keyLocationMapMaximumGetAttempts,
                keyLocationMapMaximumPutAttempts: config.contentAddressableStorageReadCache.keyLocationMapMaximumPutAttempts,
                oldBlocks: config.contentAddressableStorageReadCache.oldBlocks,
                currentBlocks: config.contentAddressableStorageReadCache.currentBlocks,
                newBlocks: config.contentAddressableStorageReadCache.newBlocks,
                blocksOnBlockDevice: {
                  source: {
                    file: {
                      path: '/storage-worker-cas/blocks',
                      sizeBytes: config.contentAddressableStorageReadCache.blocksSizeBytes,
                    },
                  },
                  spareBlocks: config.contentAddressableStorageReadCache.spareBlocks,
                } + dataIntegrityValidationCache,
                persistent: {
                  stateDirectoryPath: '/storage-worker-cas/persistent_state',
                  minimumEpochInterval: '300s',
                },
              },
            },
            replicator: { deduplicating: { 'local': {} } },
          },
        },
      },
      browserUrl: common.browserUrl,
      maximumMessageSizeBytes: common.maximumMessageSizeBytes,
      scheduler: { address: 'scheduler:8983' },
    } + filePoolConfig + {
      global: common.global {
        setUmask: { umask: 0 },
      },
      buildDirectories: [(
        if useVirtual then virtualBuildDirectoryConfig else nativeBuildDirectory
      ) + {
        runners: [{
          endpoint: { address: 'unix:///worker/runner' },
          concurrency: config.concurrency,
          platform: {
            properties: config.platformProperties,
          },
          environmentVariables: config.environmentVariables,
          workerId: {
            pod: std.extVar('POD_NAME'),
            node: std.extVar('NODE_NAME'),
          },
          // size_class (bb_worker.RunnerConfiguration field 12). Omitted when 0
          // so single-size pools render exactly as before; a value >0 makes this
          // pool one class of a multi-size-class queue for the ISCC to route on.
          // Kept in sync with the operator's embedded generatedWorkerCommonLibsonnet.
          [if std.objectHas(config, 'sizeClass') && config.sizeClass != 0 then 'sizeClass']: config.sizeClass,
        } + virtualRunnerExtras],
      }],
      inputDownloadConcurrency: config.inputDownloadConcurrency,
      outputUploadConcurrency: config.outputUploadConcurrency,
      directoryCache: {
        maximumCount: config.directoryCache.maximumCount,
        maximumSizeBytes: config.directoryCache.maximumSizeBytes,
        cacheReplacementPolicy: config.directoryCache.cacheReplacementPolicy,
      },
    } + completedActionLoggers + prefetchingConfig
  ),

  runnerConfig(runner):: (
    {
      buildDirectoryPath: '/worker/build',
      global: common.global {
        diagnosticsHttpServer:: null,
      },
      grpcServers: [{
        listenPaths: ['/worker/runner'],
        authenticationPolicy: { allow: {} },
      }],
      set_tmpdir_environment_variable: runner.setTmpdirEnvironmentVariable,
    } + (
      if !runner.runCommandsAs.enabled then {} else {
        runCommandsAs: {
          userId: runner.runCommandsAs.userId,
          groupId: runner.runCommandsAs.groupId,
        },
      }
    )
  ),
}
