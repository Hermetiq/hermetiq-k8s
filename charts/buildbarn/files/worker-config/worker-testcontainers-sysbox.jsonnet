local wc = import 'worker-common.libsonnet';

wc.workerConfig(
  config={{ .Values.workerTestcontainersSysbox.config | toJson }},
  runner={{ .Values.workerTestcontainersSysbox.runner | toJson }},
)
