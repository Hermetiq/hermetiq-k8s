local wc = import 'worker-common.libsonnet';

wc.runnerConfig(
  runner={{ .Values.workerTestcontainers.runner | toJson }},
)
