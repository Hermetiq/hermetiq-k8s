local wc = import 'worker-common.libsonnet';

wc.workerConfig(
  config={{ .Values.workerTestcontainers.config | toJson }},
  runner={{ .Values.workerTestcontainers.runner | toJson }},
)
