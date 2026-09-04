{{/* Expand the name of the chart. */}}
{{- define "universal-chart.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Create a default fully qualified app name. */}}
{{- define "universal-chart.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{/* Common labels */}}
{{- define "universal-chart.labels" -}}
helm.sh/chart: {{ include "universal-chart.chart" . }}
{{ include "universal-chart.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/* Selector labels */}}
{{- define "universal-chart.selectorLabels" -}}
app.kubernetes.io/name: {{ include "universal-chart.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/* Chart name and version */}}
{{- define "universal-chart.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Vault API address: HTTPS preferred; HTTP fallback when useAddressFallback is set (Kind in-cluster). */}}
{{- define "universal-chart.vaultAddress" -}}
{{- $useFb := or .Values.global.vault.useAddressFallback (and .Values.vault .Values.vault.useAddressFallback | default false) -}}
{{- $fallback := .Values.global.vault.addressFallback | default (and .Values.vault .Values.vault.addressFallback) | default "http://vault.vault.svc:8200" -}}
{{- $preferred := .Values.global.vault.address | default (and .Values.vault .Values.vault.address) | default "https://vault.asrax.in" -}}
{{- if $useFb -}}
{{- $fallback -}}
{{- else -}}
{{- $preferred -}}
{{- end -}}
{{- end }}

{{/* CSI vaultAuthMountPath is the mount name without the auth/ prefix. */}}
{{- define "universal-chart.vaultAuthMountPath" -}}
{{- $p := and .Values.vault .Values.vault.authPath | default .Values.global.vault.authPath | default "auth/kubernetes" -}}
{{- trimPrefix "auth/" $p -}}
{{- end }}
