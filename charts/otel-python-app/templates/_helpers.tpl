{{/*
Expand the name of the chart.
*/}}
{{- define "otel-python-app.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "otel-python-app.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "otel-python-app.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Bounded release labels shared by the Deployment and Pod template. Full commit,
deployment ID and timestamps are annotations to avoid label cardinality.
*/}}
{{- define "otel-python-app.observabilityLabels" -}}
app.kubernetes.io/version: {{ .Values.observability.version | default .Chart.AppVersion | quote }}
app.kubernetes.io/component: {{ .Values.observability.component | quote }}
app.kubernetes.io/part-of: {{ .Values.observability.partOf | quote }}
observability.grafana.com/service-name: {{ .Values.observability.serviceName | quote }}
observability.grafana.com/environment: {{ .Values.observability.environment | quote }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "otel-python-app.labels" -}}
helm.sh/chart: {{ include "otel-python-app.chart" . }}
{{ include "otel-python-app.selectorLabels" . }}
{{ include "otel-python-app.observabilityLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "otel-python-app.selectorLabels" -}}
app.kubernetes.io/name: {{ include "otel-python-app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
