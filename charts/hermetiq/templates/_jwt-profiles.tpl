{{/* Profiles are complete independent trust configurations, never inherited. */}}
{{- define "hermetiq-core.jwtProfilesJSON" -}}
{{- $out := list -}}
{{- range $index, $profile := . -}}
{{- $copy := deepCopy $profile -}}
{{- if $profile.existingSecret -}}
{{- $_ := set $copy "jwksFile" (printf "/config/jwt-profiles/%d/jwks.json" $index) -}}
{{- end -}}
{{- $_ := unset $copy "existingSecret" -}}
{{- $_ := unset $copy "existingSecretKey" -}}
{{- $out = append $out $copy -}}
{{- end -}}
{{- toJson $out -}}
{{- end -}}

{{- define "hermetiq-core.jwtProfileVolumes" -}}
{{- range $index, $profile := . -}}
{{- if $profile.existingSecret }}
- name: jwt-profile-{{ $index }}
  secret:
    secretName: {{ $profile.existingSecret | quote }}
    items:
      - key: {{ default "jwks.json" $profile.existingSecretKey | quote }}
        path: jwks.json
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "hermetiq-core.jwtProfileMounts" -}}
{{- range $index, $profile := . -}}
{{- if $profile.existingSecret }}
- name: jwt-profile-{{ $index }}
  mountPath: {{ printf "/config/jwt-profiles/%d" $index | quote }}
  readOnly: true
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "hermetiq-core.validateJWTProfiles" -}}
{{- $names := dict -}}
{{- range . -}}
{{- if or (not .name) (hasKey $names .name) -}}
{{- fail "JWT profiles require unique nonempty names" -}}
{{- end -}}
{{- $_ := set $names .name true -}}
{{- if or (not .issuer) (not .audiences) -}}
{{- fail "JWT profiles require issuer and audiences" -}}
{{- end -}}
{{- if ne (len (compact (list .jwksUrl .jwksInline .existingSecret))) 1 -}}
{{- fail "each JWT profile requires exactly one jwksUrl, jwksInline, or existingSecret" -}}
{{- end -}}
{{- if not (has .credentialUse (list "browser" "build")) -}}
{{- fail "JWT profile credentialUse must be browser or build" -}}
{{- end -}}
{{- if not (has .principalKind (list "human" "service")) -}}
{{- fail "JWT profile principalKind must be human or service" -}}
{{- end -}}
{{- end -}}
{{- end -}}
