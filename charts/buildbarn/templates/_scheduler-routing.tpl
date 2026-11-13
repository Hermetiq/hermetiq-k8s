{{/* Shared routing fields; keep the inline form when hot reload is disabled. */}}
{{- define "buildbarn.schedulerRouting" -}}
  actionRouter: {
    {{- if eq .Values.scheduler.actionRouter.mode "simple" }}
    simple: {
      platformKeyExtractor: { action: {} },
      {{ include "buildbarn.schedulerRouterTail" . | indent 6 | trim }}
    },
    {{- else if eq .Values.scheduler.actionRouter.mode "demultiplexing" }}
    {{- /* A catch-all. Platform matching has no fallback of its own — the queue
         key is the marshalled platform compared by exact string equality — so
         the only way to serve an action whose platform matches no pool is to
         route the leftovers to a router that REWRITES their platform onto one
         that does exist. Both halves are required: a defaultActionRouter that
         keeps the `action` extractor matches the leftovers exactly as before
         and still finds no pool. */}}
    demultiplexing: {
      platformKeyExtractor: { action: {} },
      backends: [
        {{- range .Values.scheduler.actionRouter.backends }}
        {
          instanceNamePrefix: {{ .instanceNamePrefix | default "" | quote }},
          platform: {
            {{ include "buildbarn.platformProperties" .platform.properties | indent 12 | trim }}
          },
          actionRouter: {
            simple: {
              platformKeyExtractor: { action: {} },
              {{ include "buildbarn.schedulerRouterTail" $ | indent 14 | trim }}
            },
          },
        },
        {{- end }}
      ],
      defaultActionRouter: {
        simple: {
          platformKeyExtractor: {
            static: {
              {{ include "buildbarn.platformProperties" .Values.scheduler.actionRouter.catchAll.platform.properties | indent 14 | trim }}
            },
          },
          {{ include "buildbarn.schedulerRouterTail" . | indent 10 | trim }}
        },
      },
    },
    {{- else if eq .Values.scheduler.actionRouter.mode "custom" }}
{{ required "scheduler.actionRouter.custom is required when mode=custom" .Values.scheduler.actionRouter.custom | nindent 4 }}
    {{- else }}
    {{- fail "scheduler.actionRouter.mode must be one of simple, demultiplexing, custom" }}
    {{- end }}
  },
  {{- if or .Values.scheduler.configurationReloadInterval .Values.scheduler.predeclaredPlatformQueues }}
  predeclaredPlatformQueues: [
    {{- range .Values.scheduler.predeclaredPlatformQueues }}
    {
      {{- if .instanceNamePrefix }}
      instanceNamePrefix: {{ .instanceNamePrefix | quote }},
      {{- end }}
      platform: { properties: {{ .platform | toJson }} },
      sizeClasses: {{ .sizeClasses | toJson }},
    },
    {{- end }}
  ],
  {{- end }}
{{- end -}}
