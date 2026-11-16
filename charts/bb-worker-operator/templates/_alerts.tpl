{{/*
Alerting rule groups shared by the VMRule and PrometheusRule templates.

bb_worker_operator.reconcile.count is exported only over OTLP, so its stored
name depends on the receiver: VictoriaMetrics keeps the dotted OTLP name by
default, while Prometheus naming gives bb_worker_operator_reconcile_count_total.
The selector matches both. The "unless ... offset" arm catches a series whose
first sample is already 1, which Prometheus's increase() reports as 0. The
namespace label comes from the k8s.namespace.name resource attribute, which
VictoriaMetrics stores as a label and Prometheus keeps in target_info.
*/}}
{{- define "bb-worker-operator.alertGroups" -}}
{{- $window := .Values.alerts.specInvalid.window -}}
{{- $selector := `{__name__=~"bb_worker_operator[._]reconcile[._]count(_total)?", result="spec_invalid"}` -}}
- name: bb-worker-operator
  rules:
    - alert: RbeWorkerSpecInvalid
      expr: |-
        sum by (namespace) (
          label_replace(
            increase({{ $selector }}[{{ $window }}]) > 0
              or ({{ $selector }} unless {{ $selector }} offset {{ $window }}),
            "namespace", "$1", "k8s.namespace.name", "(.+)"
          )
        ) > 0
      labels:
        severity: {{ .Values.alerts.specInvalid.severity | quote }}
        {{- with .Values.alerts.specInvalid.labels }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
      annotations:
        summary: bb-worker-operator refused an RbeWorker spec
        description: >-
          The bb-worker-operator{{`{{ with $labels.namespace }} in namespace {{ . }}{{ end }}`}}
          refused at least one RbeWorker spec in the last {{ $window }}. A refused RbeWorker
          reports Ready=False with reason SpecInvalid, and its existing Deployment
          keeps running the previous spec. Run `kubectl get rbeworker -A` and read
          the Ready and ConfigReady condition messages. If a message names a pod
          policy limit (a ServiceAccount or token mount, a hostPath prefix, a
          privileged extra container or a ClusterTriggerAuthentication), allow it
          with the matching operator flag in extraArgs, such as
          --allowed-host-path-prefixes; otherwise fix the RbeWorker spec. This
          alert counts refusals, so it clears after {{ $window }} even if the
          RbeWorker is still invalid.
{{- end -}}
