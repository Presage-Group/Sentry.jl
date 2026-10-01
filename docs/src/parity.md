# Parity with sentry-python

Sentry.jl follows the [Python SDK](https://github.com/getsentry/sentry-python):
the same concepts, option names and wire format. This page lists its public
API and options, and where each is in Sentry.jl.

✅ available · 🟡 available with differences · ➖ not applicable to Julia

## Top level API

| Python | Sentry.jl | |
|:--|:--|:--|
| `init` | [`Sentry.init`](@ref) | ✅ |
| `capture_event`, `capture_message`, `capture_exception` | [`capture_event`](@ref), [`capture_message`](@ref), [`capture_exception`](@ref) | ✅ |
| `add_breadcrumb`, `add_attachment` | [`add_breadcrumb`](@ref), [`add_attachment`](@ref) | ✅ |
| `set_tag`, `set_tags`, `set_extra`, `set_context`, `set_user`, `set_level` | same names | ✅ |
| `set_attribute`, `set_attributes`, `remove_attribute` | `Sentry.set_attribute`, ... | ✅ |
| `last_event_id`, `is_initialized`, `get_client` | same names | ✅ |
| `flush`, `Client.close` | `Sentry.flush()`, `Sentry.close()` | ✅ |
| `flush_async` | — | ➖ `Sentry.flush` does not block other tasks |
| `new_scope`, `isolation_scope`, `push_scope`, `configure_scope` | same names, with a `do` block | ✅ |
| `get_current_scope`, `get_isolation_scope`, `get_global_scope` | same names | ✅ |
| `start_transaction`, `start_span`, `get_current_span` | same names; `do` blocks instead of `with` | ✅ |
| `continue_trace`, `get_traceparent`, `get_baggage` | same names | ✅ |
| `trace` (decorator) | `Sentry.@trace` | ✅ |
| `set_transaction_name`, `update_current_span`, `set_measurement` | same names | ✅ |
| `start_session`, `end_session` | same names | ✅ |
| `monitor`, `crons.capture_checkin` | `Sentry.monitor`, `Sentry.@monitor`, [`capture_checkin`](@ref) | ✅ |
| `logger.info` etc. | `Sentry.Logs.info` etc. | ✅ |
| `metrics.count`, `gauge`, `distribution` | `Sentry.Metrics.count` etc. | ✅ |
| `profiler.start_profiler`, `stop_profiler` | `Sentry.start_profiler`, `Sentry.stop_profiler` | ✅ |
| `feature_flags.add_feature_flag` | [`add_feature_flag`](@ref) | ✅ |
| `Scope`, `Client`, `Transport`, `HttpTransport` | `Sentry.Scope`, `Sentry.Client`, `Sentry.AbstractTransport`, `Sentry.HttpTransport` | ✅ |
| `Hub` | — | ➖ deprecated in Python; use scopes |

## Options

| Option | | Notes |
|:--|:--|:--|
| `dsn`, `debug`, `release`, `environment`, `dist`, `server_name` | ✅ | Same environment variable fallbacks. |
| `sample_rate`, `error_sampler`, `ignore_errors` | ✅ | `ignore_errors` takes types, names or predicates. |
| `before_send`, `before_breadcrumb`, `before_send_transaction`, `before_send_log`, `before_send_metric`, `before_send_span` | ✅ | |
| `max_breadcrumbs`, `attach_stacktrace`, `send_default_pii`, `event_scrubber` | ✅ | |
| `in_app_include`, `in_app_exclude`, `project_root` | ✅ | Module name prefixes. |
| `include_source_context`, `max_stack_frames`, `max_value_length`, `custom_repr` | ✅ | |
| `include_local_variables` | ➖ | Julia has no access to the local variables of stack frames. |
| `add_full_stack` | 🟡 | Accepted; Julia backtraces always hold the full stack. |
| `max_request_body_size` | ✅ | For the HTTP middleware. |
| `integrations`, `default_integrations`, `auto_enabling_integrations`, `disabled_integrations` | ✅ | |
| `transport`, `transport_queue_size`, `shutdown_timeout` | ✅ | |
| `http_proxy`, `https_proxy`, `ca_certs`, `cert_file`, `key_file` | ✅ | |
| `proxy_headers` | 🟡 | HTTP.jl can not send them; put credentials in the proxy URL. |
| `socket_options`, `keep_alive` | 🟡 | `keep_alive` is accepted (HTTP.jl reuses connections); `socket_options` is not. |
| `send_client_reports`, `enable_backpressure_handling`, `spotlight` | ✅ | |
| `traces_sample_rate`, `traces_sampler`, `enable_tracing` | ✅ | Samplers from Sentry.jl 0.2 still work. |
| `trace_propagation_targets`, `propagate_traces`, `strict_trace_continuation`, `org_id` | ✅ | |
| `ignore_spans`, `trace_ignore_status_codes`, `trace_lifecycle` | ✅ | |
| `functions_to_trace` | ➖ | Julia functions can not be wrapped after the fact; use `Sentry.@trace`. |
| `enable_db_query_source`, `db_query_source_threshold_ms`, `enable_http_request_source`, `http_request_source_threshold_ms` | ✅ | |
| `profiles_sample_rate`, `profiles_sampler`, `profile_session_sample_rate`, `profile_lifecycle` | ✅ | |
| `profiler_mode` | ➖ | There is one profiler in Julia. |
| `auto_session_tracking` | ✅ | Also tracks an application session. |
| `enable_logs`, `enable_metrics` | ✅ | |
| `instrumenter`, `data_collection`, `stream_gen_ai_spans` | ➖ | OpenTelemetry and AI features, see below. |
| `_experiments` | ✅ | Accepted. |

## Integrations

| Python integration | Sentry.jl |
|:--|:--|
| `LoggingIntegration`, `loguru` | `LoggingIntegration` (Julia's logging) |
| `ExcepthookIntegration`, `SysExitIntegration` | `ExcepthookIntegration` (uncaught errors in scripts, crashed sessions) |
| `AtexitIntegration`, `DedupeIntegration`, `ModulesIntegration`, `ArgvIntegration` | same names |
| `StdlibIntegration` (runtime context, `http.client`) | `RuntimeContextIntegration`, `HTTPIntegration` |
| `ThreadingIntegration`, `asyncio` | `TasksIntegration` (scoped values), `Sentry.errormonitor` |
| `CloudResourceContextIntegration`, `aws_lambda`, `gcp` | `CloudResourceContextIntegration` (from environment variables) |
| `httpx`, `requests`, `aiohttp` (client) | `Sentry.http_request` (HTTP.jl) |
| `wsgi`, `asgi`, `flask`, `fastapi`, `django`, ... | `Sentry.http_middleware` (HTTP.jl, Oxygen.jl) |
| `sqlalchemy`, `asyncpg`, `pymongo`, ... | `Sentry.traced_connection` (DBInterface.jl), `Sentry.db_span` |
| `celery`, `rq`, `ray`, `spark`, ... | Distributed.jl extension, `Sentry.traced` |
| `redis`, `clickhouse`, `boto3`, `grpc`, `graphql` | ➖ no Julia equivalents in common use; use spans (`start_span`, `db_span`) |
| `openai`, `anthropic`, `langchain`, ... (AI monitoring) | ➖ not yet |
| `opentelemetry`, `otlp` | ➖ not yet |
| `executing`, `pure_eval`, `gnu_backtrace`, `unraisablehook` | ➖ CPython specific |
| Feature flag providers (`launchdarkly`, `openfeature`, `statsig`, `unleash`) | ➖ call [`add_feature_flag`](@ref) when evaluating flags |
