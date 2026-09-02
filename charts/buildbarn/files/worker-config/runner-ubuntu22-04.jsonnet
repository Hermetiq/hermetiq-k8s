local wc = import 'worker-common.libsonnet';

wc.runnerConfig(
  runner={{ .Values.workerUbuntu2204.runner | toJson }},
)
