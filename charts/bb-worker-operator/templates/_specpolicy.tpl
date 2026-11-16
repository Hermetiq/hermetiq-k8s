{{/*
Returns "true" when the node path in .path is under one of .prefixes. Mirrors
validateHostPath in the operator's internal/controller/rbeworker_policy.go.
*/}}
{{- define "bb-worker-operator.hostPathAllowed" -}}
{{- $path := .path | toString -}}
{{- $allowed := false -}}
{{- if and (not (has ".." (splitList "/" $path))) (hasPrefix "/" $path) -}}
{{- $clean := clean $path -}}
{{- range .prefixes -}}
{{- if not (has ".." (splitList "/" .)) -}}
{{- $prefix := clean . -}}
{{- if and (hasPrefix "/" $prefix) (or (eq $prefix "/") (eq $clean $prefix) (hasPrefix (printf "%s/" $prefix) $clean)) -}}
{{- $allowed = true -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if $allowed }}true{{ end -}}
{{- end -}}

{{/*
Lists, one per line, why existing RbeWorkers would stop reconciling under
operator v0.3.13: reason SpecInvalid under .Values.specPolicy
(validatePodPolicy and validateTriggerAuthenticationPolicy in
internal/controller/rbeworker_policy.go), or reason NameConflict
(claimControl and resolveGeneratedConfig in rbeworker_controller.go). Keep it
in step with those. It reads the RbeWorkers the manager watches through
lookup, so it returns nothing when Helm renders without a cluster.
*/}}
{{- define "bb-worker-operator.specPolicyViolations" -}}
{{- $policy := .Values.specPolicy -}}
{{- $releaseNamespace := include "bb-worker-operator.namespace" . -}}
{{- $scope := "" -}}
{{- if eq .Values.rbac.mode "namespace" -}}
{{- $scope = $releaseNamespace -}}
{{- else if .Values.watchNamespace -}}
{{- $scope = .Values.watchNamespace -}}
{{- end -}}
{{- $operatorServiceAccount := include "bb-worker-operator.serviceAccountName" . -}}
{{- $serviceAccounts := $policy.allowedPodServiceAccounts | default list -}}
{{- $prefixes := $policy.allowedHostPathPrefixes | default list -}}
{{- $clusterTriggerAuthentications := $policy.allowedClusterTriggerAuthentications | default list -}}
{{- $workers := lookup "bb.hermetiq.com/v1" "RbeWorker" $scope "" -}}
{{- range $worker := (dig "items" list $workers) -}}
{{- $id := printf "%s/%s" $worker.metadata.namespace $worker.metadata.name -}}
{{- $spec := $worker.spec | default dict -}}
{{- $problems := list -}}

{{- /* ServiceAccount and token mounts */ -}}
{{- $serviceAccount := dig "pod" "serviceAccountName" "" $spec | default "default" -}}
{{- $serviceAccountAllowed := or (has "*" $serviceAccounts) (has $serviceAccount $serviceAccounts) -}}
{{- if and (eq $serviceAccount $operatorServiceAccount) (eq $worker.metadata.namespace $releaseNamespace) -}}
{{- $problems = append $problems (printf "spec.pod.serviceAccountName %q is the operator's own ServiceAccount, which is never allowed" $serviceAccount) -}}
{{- else if and (ne $serviceAccount "default") (not $serviceAccountAllowed) -}}
{{- $problems = append $problems (printf "spec.pod.serviceAccountName %q needs specPolicy.allowedPodServiceAccounts to include it" $serviceAccount) -}}
{{- else if and (eq (dig "pod" "automountServiceAccountToken" false $spec | toString) "true") (not $serviceAccountAllowed) -}}
{{- $problems = append $problems (printf "spec.pod.automountServiceAccountToken needs specPolicy.allowedPodServiceAccounts to include %q" $serviceAccount) -}}
{{- end -}}

{{- /* Volume sources the RbeWorker places in the pod */ -}}
{{- $volumes := list
      (dict "field" "spec.storage.workerVolume" "source" (dig "storage" "workerVolume" nil $spec))
      (dict "field" "spec.storage.casVolume" "source" (dig "storage" "casVolume" nil $spec))
      (dict "field" "spec.docker.dind.storageVolume" "source" (dig "docker" "dind" "storageVolume" nil $spec)) -}}
{{- range (dig "pod" "extraVolumes" list $spec) -}}
{{- $volumes = append $volumes (dict "field" (printf "spec.pod.extraVolumes[%s]" .name) "source" .) -}}
{{- end -}}
{{- range $volumes -}}
{{- $field := .field -}}
{{- with .source -}}
{{- with .hostPath -}}
{{- if not (include "bb-worker-operator.hostPathAllowed" (dict "path" .path "prefixes" $prefixes)) -}}
{{- $problems = append $problems (printf "%s.hostPath.path %q needs a covering entry in specPolicy.allowedHostPathPrefixes" $field (.path | toString)) -}}
{{- end -}}
{{- end -}}
{{- if not $serviceAccountAllowed -}}
{{- range (dig "projected" "sources" list .) -}}
{{- if .serviceAccountToken -}}
{{- $problems = append $problems (printf "%s projects a ServiceAccount token, which needs specPolicy.allowedPodServiceAccounts to include %q" $field $serviceAccount) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- /* FUSE device */ -}}
{{- with (dig "storage" "fuse" nil $spec) -}}
{{- $path := .path | default "/dev/fuse" | toString -}}
{{- $type := .type | default "CharDevice" -}}
{{- if or (has ".." (splitList "/" $path)) (ne (clean $path) "/dev/fuse") (ne $type "CharDevice") -}}
{{- if not (include "bb-worker-operator.hostPathAllowed" (dict "path" $path "prefixes" $prefixes)) -}}
{{- $problems = append $problems (printf "spec.storage.fuse %q (type %s) needs a covering entry in specPolicy.allowedHostPathPrefixes" $path $type) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- /* Extra containers */ -}}
{{- if not $policy.allowPrivilegedExtraContainers -}}
{{- range $group := list "extraInitContainers" "extraContainers" -}}
{{- range (dig "pod" $group list $spec) -}}
{{- $securityContext := .securityContext | default dict -}}
{{- $procMount := $securityContext.procMount | default "Default" -}}
{{- if or (eq ($securityContext.privileged | toString) "true") (dig "capabilities" "add" list $securityContext) (ne $procMount "Default") -}}
{{- $problems = append $problems (printf "spec.pod.%s %q is privileged, adds capabilities or sets procMount, which needs specPolicy.allowPrivilegedExtraContainers=true" $group (.name | toString)) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- /* KEDA ClusterTriggerAuthentication references */ -}}
{{- if eq (dig "autoscaling" "enabled" false $spec | toString) "true" -}}
{{- $refs := list (dict "field" "spec.autoscaling.prometheus.authenticationRef" "ref" (dig "autoscaling" "prometheus" "authenticationRef" nil $spec)) -}}
{{- range $i, $trigger := (dig "autoscaling" "additionalTriggers" list $spec) -}}
{{- $refs = append $refs (dict "field" (printf "spec.autoscaling.additionalTriggers[%d].authenticationRef" $i) "ref" $trigger.authenticationRef) -}}
{{- end -}}
{{- range $refs -}}
{{- $field := .field -}}
{{- with .ref -}}
{{- if and (eq (.kind | toString) "ClusterTriggerAuthentication") (not (or (has "*" $clusterTriggerAuthentications) (has .name $clusterTriggerAuthentications))) -}}
{{- $problems = append $problems (printf "%s ClusterTriggerAuthentication %q needs specPolicy.allowedClusterTriggerAuthentications to include it" $field (.name | toString)) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- /* Objects named after the RbeWorker that it does not control
       (claimControl and resolveGeneratedConfig) */ -}}
{{- $config := dig "config" dict $spec -}}
{{- $owned := list (dict "apiVersion" "apps/v1" "kind" "Deployment" "name" $worker.metadata.name) -}}
{{- if and (hasKey $config "generated") (not (kindIs "invalid" $config.generated)) -}}
{{- $generated := $config.generated -}}
{{- $configMapName := printf "%s-config" $worker.metadata.name -}}
{{- if eq ($generated.commonConfigMapName | toString) $configMapName -}}
{{- $problems = append $problems (printf "spec.config.generated.commonConfigMapName %q is the ConfigMap the operator generates for this RbeWorker (NameConflict)" $configMapName) -}}
{{- end -}}
{{- $owned = append $owned (dict "apiVersion" "v1" "kind" "ConfigMap" "name" $configMapName) -}}
{{- end -}}
{{- if and (eq (dig "autoscaling" "enabled" false $spec | toString) "true") ($.Capabilities.APIVersions.Has "keda.sh/v1alpha1/ScaledObject") -}}
{{- $owned = append $owned (dict "apiVersion" "keda.sh/v1alpha1" "kind" "ScaledObject" "name" $worker.metadata.name) -}}
{{- end -}}
{{- range $owned -}}
{{- $object := lookup .apiVersion .kind $worker.metadata.namespace .name -}}
{{- if $object -}}
{{- $controlled := false -}}
{{- range (dig "metadata" "ownerReferences" list $object) -}}
{{- if and (eq (.controller | toString) "true") (eq (.uid | toString) ($worker.metadata.uid | toString)) -}}
{{- $controlled = true -}}
{{- end -}}
{{- end -}}
{{- if not $controlled -}}
{{- $problems = append $problems (printf "%s %q exists but is not controlled by this RbeWorker (NameConflict); remove it or set this RbeWorker as its controller owner" .kind .name) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- range $problems }}
  - {{ $id }}: {{ . }}
{{- end -}}
{{- end -}}
{{- end -}}
