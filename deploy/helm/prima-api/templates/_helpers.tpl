{{/*
Common template helpers. Keeping naming and labelling in one place is what
stops selectors and resource names from drifting apart between templates.
*/}}

{{- define "prima-api.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Fully qualified name, capped at the 63-char DNS label limit. */}}
{{- define "prima-api.fullname" -}}
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

{{- define "prima-api.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Labels on every object. Only the selector subset may ever change. */}}
{{- define "prima-api.labels" -}}
helm.sh/chart: {{ include "prima-api.chart" . }}
{{ include "prima-api.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: prima-tech-challenge
{{- end }}

{{/*
Selector labels are immutable on a Deployment: they must stay minimal, or a
chart upgrade turns into "field is immutable" and a manual delete.
*/}}
{{- define "prima-api.selectorLabels" -}}
app.kubernetes.io/name: {{ include "prima-api.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "prima-api.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "prima-api.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/* Image reference: an explicit tag wins, otherwise the chart's appVersion. */}}
{{- define "prima-api.image" -}}
{{- printf "%s:%s" .Values.image.repository (default .Chart.AppVersion .Values.image.tag) }}
{{- end }}

{{/* Name of the Secret holding static AWS credentials (local clusters only). */}}
{{- define "prima-api.secretName" -}}
{{- if .Values.aws.staticCredentials.existingSecret }}
{{- .Values.aws.staticCredentials.existingSecret }}
{{- else }}
{{- printf "%s-aws" (include "prima-api.fullname" .) }}
{{- end }}
{{- end }}

{{/* Fail fast on configurations that would only break at runtime. */}}
{{- define "prima-api.validateValues" -}}
{{- if and .Values.aws.staticCredentials.enabled .Values.serviceAccount.annotations }}
{{- if index .Values.serviceAccount.annotations "eks.amazonaws.com/role-arn" }}
{{- fail "Set either IRSA (serviceAccount role-arn) or aws.staticCredentials, never both." }}
{{- end }}
{{- end }}
{{- if and (not .Values.autoscaling.enabled) (lt (int .Values.replicaCount) 1) }}
{{- fail "replicaCount must be >= 1 when autoscaling is disabled." }}
{{- end }}
{{- end }}
