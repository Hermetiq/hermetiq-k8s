local wc = import 'worker-common.libsonnet';

wc.runnerConfig(
  runner={{ .Values.workerTestcontainersSysbox.runner | toJson }},
)
