{{/*
Expand the name of the chart.
*/}}
{{- define "frontend-app.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "frontend-app.fullname" -}}
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
Chart name and version as used by the chart label.
*/}}
{{- define "frontend-app.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Bounded release labels shared by the Deployment and Pod template. Full commit,
deployment ID and timestamps are annotations to avoid label cardinality.
*/}}
{{- define "frontend-app.observabilityLabels" -}}
app.kubernetes.io/version: {{ .Values.observability.version | default .Chart.AppVersion | quote }}
app.kubernetes.io/component: {{ .Values.observability.component | quote }}
app.kubernetes.io/part-of: {{ .Values.observability.partOf | quote }}
observability.grafana.com/service-name: {{ .Values.observability.serviceName | quote }}
observability.grafana.com/environment: {{ .Values.observability.environment | quote }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "frontend-app.labels" -}}
helm.sh/chart: {{ include "frontend-app.chart" . }}
{{ include "frontend-app.selectorLabels" . }}
{{ include "frontend-app.observabilityLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "frontend-app.selectorLabels" -}}
app.kubernetes.io/name: {{ include "frontend-app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
