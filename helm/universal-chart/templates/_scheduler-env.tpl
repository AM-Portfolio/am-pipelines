{{/*
  Emits all SCHEDULER_* and REDIS_* env vars from Values.config.scheduler
  and Values.config.redis when those blocks are set (am-market-data).

  Every cron / flag / TTL that was previously hardcoded in application.yml
  is now driven from Helm values so each environment can tune them independently
  without a code change.
*/}}
{{- define "universal-chart.schedulerEnv" -}}
{{- with .Values.config }}
{{- with .scheduler }}

{{/* ── Timezone ── */}}
{{- with .timezone }}
- name: SCHEDULER_TIMEZONE
  value: {{ . | quote }}
{{- end }}

{{/* ── Cookie / NSE session ── */}}
{{- with .cookie }}
{{- if hasKey . "enabled" }}
- name: SCHEDULER_COOKIE_ENABLED
  value: {{ .enabled | quote }}
{{- end }}
{{- with .refreshCron }}
- name: SCHEDULER_COOKIE_REFRESH_CRON
  value: {{ . | quote }}
{{- end }}
{{- end }}

{{/* ── Stock-indices ── */}}
{{- with .stockIndices }}
{{- if hasKey . "enabled" }}
- name: SCHEDULER_STOCK_INDICES_ENABLED
  value: {{ .enabled | quote }}
{{- end }}
{{- with .morningFetchCron }}
- name: SCHEDULER_STOCK_INDICES_MORNING_FETCH_CRON
  value: {{ . | quote }}
{{- end }}
{{- with .eveningFetchCron }}
- name: SCHEDULER_STOCK_INDICES_EVENING_FETCH_CRON
  value: {{ . | quote }}
{{- end }}
{{- with .retry }}
{{- with .cron }}
- name: SCHEDULER_STOCK_INDICES_RETRY_CRON
  value: {{ . | quote }}
{{- end }}
{{- with .intervalMinutes }}
- name: SCHEDULER_STOCK_INDICES_RETRY_INTERVAL_MINUTES
  value: {{ . | quote }}
{{- end }}
{{- with .maxRetries }}
- name: SCHEDULER_STOCK_INDICES_RETRY_MAX_RETRIES
  value: {{ . | quote }}
{{- end }}
{{- end }}
{{- end }}

{{/* ── Intra-day indices fetch ── */}}
{{- with .indices }}
{{- with .fetchCron }}
- name: SCHEDULER_INDICES_FETCH_CRON
  value: {{ . | quote }}
{{- end }}
{{- end }}

{{/* ── Ingestion ── */}}
{{- with .ingestion }}
{{- if hasKey . "enabled" }}
- name: SCHEDULER_INGESTION_ENABLED
  value: {{ .enabled | quote }}
{{- end }}
{{- with .provider }}
- name: SCHEDULER_INGESTION_PROVIDER
  value: {{ . | quote }}
{{- end }}
{{- if hasKey . "force" }}
- name: SCHEDULER_INGESTION_FORCE
  value: {{ .force | quote }}
{{- end }}
{{- if hasKey . "useWebsocket" }}
- name: SCHEDULER_INGESTION_USE_WEBSOCKET
  value: {{ .useWebsocket | quote }}
{{- end }}
{{- if hasKey . "pollEnabled" }}
- name: SCHEDULER_INGESTION_POLL_ENABLED
  value: {{ .pollEnabled | quote }}
{{- end }}
{{- if hasKey . "pollHistorical" }}
- name: SCHEDULER_INGESTION_POLL_HISTORICAL
  value: {{ .pollHistorical | quote }}
{{- end }}
{{- with .symbols }}
- name: SCHEDULER_INGESTION_SYMBOLS
  value: {{ . | quote }}
{{- end }}
{{- with .startCron }}
- name: SCHEDULER_INGESTION_START_CRON
  value: {{ . | quote }}
{{- end }}
{{- with .stopCron }}
- name: SCHEDULER_INGESTION_STOP_CRON
  value: {{ . | quote }}
{{- end }}
{{- end }}

{{/* ── Market window ── */}}
{{- with .market }}
{{- with .start }}
- name: SCHEDULER_MARKET_START
  value: {{ . | quote }}
{{- end }}
{{- with .end }}
- name: SCHEDULER_MARKET_END
  value: {{ . | quote }}
{{- end }}
{{- end }}

{{/* ── Historical sync ── */}}
{{- with .historical }}
{{- with .syncCron }}
- name: SCHEDULER_HISTORICAL_SYNC_CRON
  value: {{ . | quote }}
{{- end }}
{{- end }}

{{/* ── Analysis ── */}}
{{- with .analysis }}
{{- with .dailyCron }}
- name: SCHEDULER_ANALYSIS_DAILY_CRON
  value: {{ . | quote }}
{{- end }}
{{- end }}

{{/* ── Stream start/stop ── */}}
{{- with .stream }}
{{- with .startCron }}
- name: SCHEDULER_STREAM_START_CRON
  value: {{ . | quote }}
{{- end }}
{{- with .stopCron }}
- name: SCHEDULER_STREAM_STOP_CRON
  value: {{ . | quote }}
{{- end }}
{{- end }}

{{/* ── Redis cleanup ── */}}
{{- with .redisCleanup }}
{{- if hasKey . "enabled" }}
- name: SCHEDULER_REDIS_CLEANUP_ENABLED
  value: {{ .enabled | quote }}
{{- end }}
{{- with .cron }}
- name: SCHEDULER_REDIS_CLEANUP_CRON
  value: {{ . | quote }}
{{- end }}
{{- end }}

{{- end }}{{/* end with .scheduler */}}

{{/* ── Redis cache TTLs & cleanup tuning ── */}}
{{- with .redis }}
{{- with .cleanupRetentionDays }}
- name: REDIS_CLEANUP_RETENTION_DAYS
  value: {{ . | quote }}
{{- end }}
{{- with .cleanupBatchSize }}
- name: REDIS_CLEANUP_BATCH_SIZE
  value: {{ . | quote }}
{{- end }}
{{- with .cacheTtl }}
{{- with .historical }}
- name: REDIS_CACHE_TTL_HISTORICAL
  value: {{ . | quote }}
{{- end }}
{{- with .analysis }}
- name: REDIS_CACHE_TTL_ANALYSIS
  value: {{ . | quote }}
{{- end }}
{{- with .intradayPast }}
- name: REDIS_CACHE_TTL_INTRADAY_PAST
  value: {{ . | quote }}
{{- end }}
{{- with .intradayFuture }}
- name: REDIS_CACHE_TTL_INTRADAY_FUTURE
  value: {{ . | quote }}
{{- end }}
{{- with .intradayBuffer }}
- name: REDIS_CACHE_TTL_INTRADAY_BUFFER
  value: {{ . | quote }}
{{- end }}
{{- end }}
{{- end }}{{/* end with .redis */}}

{{- end }}{{/* end with .Values.config */}}
{{- end }}{{/* end define */}}
