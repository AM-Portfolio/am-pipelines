{{/*
  Emits BATCH_SEARCH_* env vars when Values.config.batchSearch is set (am-market-data).
  Controls Redis cache for POST /v1/securities/batch-search.
*/}}
{{- define "universal-chart.batchSearchEnv" -}}
{{- with .Values.config.batchSearch }}
- name: BATCH_SEARCH_CACHE_ENABLED
  value: {{ .cacheEnabled | default true | quote }}
{{- with .maxQueries }}
- name: BATCH_SEARCH_MAX_QUERIES
  value: {{ . | quote }}
{{- end }}
{{- with .internalBatchSize }}
- name: BATCH_SEARCH_INTERNAL_BATCH_SIZE
  value: {{ . | quote }}
{{- end }}
{{- with .mongoQueryLimit }}
- name: BATCH_SEARCH_MONGO_QUERY_LIMIT
  value: {{ . | quote }}
{{- end }}
{{- with .maxCandidatesPerQuery }}
- name: BATCH_SEARCH_MAX_CANDIDATES
  value: {{ . | quote }}
{{- end }}
{{- end }}
{{- end }}
