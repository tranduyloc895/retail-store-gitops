{{- define "microservice.labels" -}}
app: {{ .Values.name }}
app.kubernetes.io/name: {{ .Values.name }}
app.kubernetes.io/part-of: retail-store
{{- end }}
