{{- define "test-services.validate" -}}
{{- if not (or (eq .Values.gatewayProvider "local-istio") (eq .Values.gatewayProvider "gke-gateway")) -}}
{{- fail (printf "unsupported gatewayProvider %q; expected local-istio or gke-gateway" .Values.gatewayProvider) -}}
{{- end -}}
{{- end -}}

{{- define "test-services.localIstioDomain" -}}
{{- regexReplaceAll "^int\\." .Values.dnsDomain "" -}}
{{- end -}}
