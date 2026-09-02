local wc = import 'worker-common.libsonnet';

wc.workerConfig(
  config={{ .Values.workerUbuntu2204.config | toJson }},
  runner={{ .Values.workerUbuntu2204.runner | toJson }},
)
